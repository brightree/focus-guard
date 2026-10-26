import Foundation
import UserNotifications

// 앱의 두뇌: 타이머 진행, 기록, 나중에 할 것, 딴짓 추적, 파일 저장.

final class Store: ObservableObject {
    static let shared = Store()

    @Published private(set) var data = DataFile()
    @Published private(set) var now = Date()
    @Published private(set) var dataDir: URL
    /// 브라우저 제어(자동화) 권한이 거부됐는지 — 패널에서 안내한다
    @Published var browserAccessDenied = false
    /// 저장에 실패했거나 막혀 있으면 그 이유 — 패널에서 안내한다
    @Published private(set) var saveError: String?

    /// 단계가 바뀔 때 UI가 창을 띄우도록 알려준다 (이전 단계, 새 단계)
    var onPhaseChange: ((Phase, Phase) -> Void)?

    private var streak: (site: String, sec: Double, lastSeen: Date, warnedMin: Int)?
    private var lastTickAt: Date?
    private var saveWork: DispatchWorkItem?
    /// data.json 이 있는데 읽지 못했으면(예: 클라우드 파일이 아직 안 내려받아짐) 덮어쓰지 않도록 저장을 막는다
    private var saveBlocked = false
    /// 1초 타이머마다 불린다 (브라우저 감시 등)
    var onSecond: (() -> Void)?
    /// 딴짓 시간은 매초 파일에 쓰지 않고 여기 모았다가 30초마다 반영한다 (날짜 → 사이트 → 초)
    private var pendingDistract: [String: [String: Double]] = [:]
    private var lastDistractFlush = Date()
    private var lastBackupKey = ""

    private static let dirKey = "dataDir"
    private static let streakGapSec: Double = 180

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.dirKey) {
            dataDir = URL(fileURLWithPath: path)
        } else {
            dataDir = Self.localDir
        }
        load()
        let t = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in self?.secondTick() }
        t.tolerance = 0.2 // 시스템이 다른 깨어남과 묶어서 처리할 수 있게
    }

    // MARK: - 파생 값

    var settings: Settings { data.settings }
    var timer: TimerState { data.timer }
    var phase: Phase { data.timer.phase }
    var isPaused: Bool { data.timer.pausedRemaining != nil }
    var isBlocking: Bool { phase.isStudy }
    var today: DayStats { data.days[dayKey(now)] ?? DayStats() }
    var openLater: [LaterItem] { data.later.filter { !$0.done } }

    var remaining: TimeInterval {
        if let p = data.timer.pausedRemaining { return p }
        if let end = data.timer.endTime { return max(0, end.timeIntervalSince(now)) }
        return TimeInterval(settings.focusMin * 60)
    }

    /// 진행 중인 구간까지 포함한 오늘 공부 시간
    var liveStudySec: Double { studySec(for: dayKey(now)) }

    func studySec(for key: String) -> Double {
        (data.days[key]?.focusSec ?? 0) + (pendingStudyByDay()[key] ?? 0)
    }

    /// 아직 기록에 반영되지 않은 진행 중 공부 시간을 날짜별로 나눈다 (자정을 넘으면 두 날로)
    private func pendingStudyByDay() -> [String: Double] {
        guard phase.isStudy, let start = data.timer.startedAt else { return [:] }
        let until = min(now, data.timer.endTime ?? now)
        var out: [String: Double] = [:]
        var s = start
        while s < until {
            let nextDay = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: s))!
            let e = min(until, nextDay)
            out[dayKey(s), default: 0] += e.timeIntervalSince(s)
            s = e
        }
        return out
    }

    // MARK: - 변경 헬퍼

    private func mutate(_ f: (inout DataFile) -> Void) {
        f(&data)
        scheduleSave()
    }

    private func updateDay(_ k: String, _ f: (inout DayStats) -> Void) {
        mutate { d in
            var day = d.days[k] ?? DayStats()
            f(&day)
            d.days[k] = day
        }
    }

    private func updateToday(_ f: (inout DayStats) -> Void) { updateDay(dayKey(), f) }

    private func flushStudyTime() {
        for (k, sec) in pendingStudyByDay() where sec > 0 { updateDay(k) { $0.focusSec += sec } }
        mutate { $0.timer.startedAt = nil }
    }

    // MARK: - 뽀모도로

    private func enter(_ phase: Phase, minutes: Int, task: String? = nil) {
        let old = self.phase
        let start = Date()
        mutate { d in
            d.timer.phase = phase
            d.timer.endTime = start.addingTimeInterval(TimeInterval(minutes * 60))
            d.timer.pausedRemaining = nil
            d.timer.startedAt = phase.isStudy ? start : nil
            if let task { d.timer.task = task }
        }
        onPhaseChange?(old, phase)
    }

    func startFocus(task: String) {
        streak = nil
        enter(.focus, minutes: settings.focusMin, task: task.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    private func phaseEnded() {
        flushStudyTime()
        switch phase {
        case .focus:
            let entry = LogEntry(task: timer.task, minutes: settings.focusMin, end: Date(), done: true)
            let k = dayKey()
            updateDay(k) { d in
                d.sessions += 1
                d.log.append(entry)
            }
            mutate { d in
                d.timer.lastLogDay = k
                d.timer.lastLogID = entry.id
            }
            enter(.wrap, minutes: settings.wrapMin)
            notify("🍅 집중 완료! 정리 \(settings.wrapMin)분", "어디까지 했는지, 다음에 뭘 할지 적고 나중에 할 것을 훑어보세요.")
        case .wrap:
            enter(.rest, minutes: settings.breakMin)
            notify("☕ 휴식 \(settings.breakMin)분", "화면에서 눈을 떼고 일어나 보세요.")
        case .rest:
            let old = phase
            mutate { d in
                d.timer.phase = .idle
                d.timer.endTime = nil
                d.timer.pausedRemaining = nil
            }
            notify("휴식 끝", "다음 뽀모도로를 시작할 시간이에요. 딱 \(settings.focusMin)분만!")
            onPhaseChange?(old, .idle)
        case .idle:
            break
        }
    }

    func finishWrap() {
        if phase == .wrap { phaseEnded() }
    }

    /// 방금 끝난 집중 세션에 정리 메모를 붙인다
    func saveNote(_ note: String) {
        guard let k = timer.lastLogDay, let id = timer.lastLogID else { return }
        updateDay(k) { d in
            if let i = d.log.firstIndex(where: { $0.id == id }) {
                d.log[i].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
    }

    var lastNote: String {
        guard let k = timer.lastLogDay, let id = timer.lastLogID else { return "" }
        return data.days[k]?.log.first { $0.id == id }?.note ?? ""
    }

    func pause() {
        guard phase != .idle, !isPaused else { return }
        let rem = remaining
        flushStudyTime()
        // 일시정지해도 phase는 그대로라 차단은 유지된다.
        mutate { d in
            d.timer.pausedRemaining = rem
            d.timer.endTime = nil
        }
    }

    func resume() {
        guard let rem = data.timer.pausedRemaining else { return }
        let start = Date()
        mutate { d in
            d.timer.endTime = start.addingTimeInterval(rem)
            d.timer.pausedRemaining = nil
            d.timer.startedAt = d.timer.phase.isStudy ? start : nil
        }
    }

    /// 집중 포기 / 휴식 건너뛰기
    func stop() {
        let old = phase
        flushStudyTime()
        if old == .focus {
            let t = timer.task
            updateToday { d in
                d.abandoned += 1
                d.log.append(LogEntry(task: t, minutes: nil, end: Date(), done: false))
            }
        }
        mutate { d in
            d.timer.phase = .idle
            d.timer.endTime = nil
            d.timer.pausedRemaining = nil
        }
        onPhaseChange?(old, .idle)
    }

    private func secondTick() {
        now = Date()
        if let end = data.timer.endTime, data.timer.pausedRemaining == nil, now >= end {
            phaseEnded()
        }
        if !pendingDistract.isEmpty, now.timeIntervalSince(lastDistractFlush) >= 30 {
            flushDistract()
            scheduleSave()
        }
        onSecond?()
    }

    // MARK: - 설정

    /// 설정을 저장하고, 사이트로 인식하지 못한 줄을 돌려준다
    @discardableResult
    func updateSettings(_ s: Settings) -> [String] {
        var s = s.clamped()
        var rejected: [String] = []
        func normalized(_ list: [String]) -> [String] {
            var out: [String] = []
            for raw in list where !raw.trimmingCharacters(in: .whitespaces).isEmpty {
                if let site = Self.normalizeSite(raw) {
                    if !out.contains(site) { out.append(site) }
                } else {
                    rejected.append(raw)
                }
            }
            return out
        }
        s.sites = normalized(s.sites)
        s.allowSites = normalized(s.allowSites)
        if s.stopPhrase.trimmingCharacters(in: .whitespaces).isEmpty { s.stopPhrase = Settings().stopPhrase }
        mutate { $0.settings = s }
        return rejected
    }

    /// "https://www.youtube.com/watch?v=1", "youtube.com:443" 등에서 도메인만 뽑는다. 도메인이 아니면 nil.
    static func normalizeSite(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if !s.contains("://") { s = "https://" + s }
        guard var host = URLComponents(string: s)?.host, host.contains("."),
              host.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "." }) else { return nil }
        if host.hasPrefix("www.") { host.removeFirst(4) }
        return host
    }

    // MARK: - 나중에 할 것

    func addLater(_ text: String) {
        let t = String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        guard !t.isEmpty, canPersist else { return } // 저장할 수 없으면 받지 않는다 (사라질 항목을 받은 척하지 않게)
        let during = phase.isStudy ? timer.task : ""
        mutate { $0.later.append(LaterItem(text: t, created: Date(), during: during)) }
    }

    func toggleLater(_ id: UUID) {
        mutate { d in
            if let i = d.later.firstIndex(where: { $0.id == id }) { d.later[i].done.toggle() }
        }
    }

    func deleteLater(_ id: UUID) { mutate { $0.later.removeAll { $0.id == id } } }
    func clearDoneLater() { mutate { $0.later.removeAll { $0.done } } }

    // MARK: - 오늘 할 일 (아침 계획)

    func addTodo(_ text: String, kind: TodoKind) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        updateToday { $0.todos.append(TodoItem(text: t, kind: kind)) }
    }

    func toggleTodo(_ id: UUID) {
        updateToday { d in
            if let i = d.todos.firstIndex(where: { $0.id == id }) { d.todos[i].done.toggle() }
        }
    }

    func deleteTodo(_ id: UUID) { updateToday { $0.todos.removeAll { $0.id == id } } }

    /// 가장 최근에 계획을 세운 날의 못 한 일
    var unfinishedFromBefore: [TodoItem] {
        let today = dayKey(now)
        guard let key = data.days.keys.filter({ $0 < today && !(data.days[$0]?.todos.isEmpty ?? true) }).max() else { return [] }
        return data.days[key]!.todos.filter { !$0.done }
    }

    func carryOver() {
        let items = unfinishedFromBefore.map { TodoItem(text: $0.text, kind: $0.kind) }
        updateToday { $0.todos.append(contentsOf: items) }
    }

    /// 오늘 처음이면 true (아침 계획 창을 하루 한 번만 자동으로 띄우기 위해)
    func shouldShowMorningPlan() -> Bool {
        let k = dayKey()
        guard data.planShownDay != k else { return false }
        mutate { $0.planShownDay = k }
        return today.todos.isEmpty
    }

    // MARK: - 브라우저 감시가 보내는 딴짓 보고

    /// 1초마다 호출된다. 경고를 띄워야 하면 (분, 사이트)를 돌려준다.
    func reportBrowsing(site: String?, active: Bool) -> (min: Int, site: String)? {
        let t = Date()
        let delta = lastTickAt.map { min(t.timeIntervalSince($0), 5) } ?? 0
        lastTickAt = t
        if let s = streak, t.timeIntervalSince(s.lastSeen) > Self.streakGapSec { streak = nil }
        guard active, let site, delta > 0 else { return nil }

        pendingDistract[dayKey(t), default: [:]][site, default: 0] += delta
        if streak?.site != site { streak = (site, 0, t, 0) }
        streak!.sec += delta
        streak!.lastSeen = t

        // 10분, 20분, 30분... 마다 경고
        let used = Int(streak!.sec / 60)
        let step = settings.warnAfterMin
        guard !isBlocking, step > 0, used >= step, used - streak!.warnedMin >= step else { return nil }
        streak!.warnedMin = used - used % step
        updateToday { $0.warnings += 1 }
        notify("⏰ 딴짓 경고", "\(site)를 \(streak!.warnedMin)분째 쓰고 있어요.")
        return (streak!.warnedMin, site)
    }

    /// 모아둔 딴짓 시간을 기록에 반영한다 (저장 예약은 하지 않음)
    private func flushDistract() {
        lastDistractFlush = Date()
        guard !pendingDistract.isEmpty else { return }
        for (k, sites) in pendingDistract {
            var day = data.days[k] ?? DayStats()
            for (site, sec) in sites { day.distractSec[site, default: 0] += sec }
            data.days[k] = day
        }
        pendingDistract = [:]
    }

    /// 앱을 삭제할 때: 이후로는 아무것도 저장하지 않는다
    func stopSaving() {
        saveWork?.cancel()
        saveWork = nil
        saveBlocked = true
    }

    /// 저장이 막혀 있거나 실패 중이면 false — "저장됐다"고 말하면 안 될 때
    var canPersist: Bool { !saveBlocked && saveError == nil }

    // MARK: - 알림

    func notify(_ title: String, _ body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        c.sound = .default
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil))
    }

    // MARK: - 저장 (data.json + 날짜별 백업)

    static let localDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("FocusGuard", isDirectory: true)

    var dataURL: URL { dataDir.appendingPathComponent("data.json") }

    private static let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        e.dateEncodingStrategy = .iso8601
        return e
    }()

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func load() {
        saveBlocked = false
        guard FileManager.default.fileExists(atPath: dataURL.path) else {
            data = DataFile()
            saveError = nil
            return
        }
        guard let raw = try? Data(contentsOf: dataURL) else {
            blockSaving("기록 파일을 읽지 못해서 원본을 지키려고 저장을 멈췄어요. 파일을 확인한 뒤 앱을 다시 켜주세요.")
            return
        }
        do {
            data = try Self.decoder.decode(DataFile.self, from: raw)
            saveError = nil
        } catch {
            // 해석할 수 없는 파일은 겹치지 않는 이름으로 복사해 두고, 복사본이 원본과 같을 때만 새로 시작한다.
            let copy = dataDir.appendingPathComponent("data.unreadable-\(Int(Date().timeIntervalSince1970))-\(UUID().uuidString.prefix(8)).json")
            do {
                try FileManager.default.copyItem(at: dataURL, to: copy)
                guard try Data(contentsOf: copy) == raw else { throw CocoaError(.fileWriteUnknown) }
                data = DataFile()
                saveError = nil
                notify("기록 파일이 손상돼 새로 시작해요", "원래 파일은 \(copy.lastPathComponent) 로 보관했어요.")
            } catch {
                blockSaving("기록 파일이 손상됐는데 보관 복사본을 만들지 못해서 저장을 멈췄어요. 원본: \(dataURL.path)")
            }
        }
    }

    private func blockSaving(_ reason: String) {
        saveBlocked = true
        saveError = reason
        data = DataFile()
        notify("기록을 저장하지 않고 있어요", reason)
    }

    /// 변경이 계속 들어와도 최대 1초 안에 한 번은 저장된다.
    private func scheduleSave() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    @discardableResult
    func saveNow() -> Bool {
        saveWork?.cancel()
        saveWork = nil
        flushDistract()
        guard !saveBlocked else { return false }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try Self.encoder.encode(data).write(to: dataURL, options: .atomic)
        } catch {
            NSLog("FocusGuard: save failed: \(error)")
            saveError = "기록을 저장하지 못했어요: \(error.localizedDescription)"
            scheduleRetry()
            return false
        }
        saveError = nil
        try? backupIfNeeded()
        return true
    }

    /// 저장에 실패하면 30초 뒤 다시 시도한다
    private func scheduleRetry() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 30, execute: work)
    }

    /// 하루 한 번 backups/data-YYYY-MM-DD.json 을 남기고 최근 14개만 유지한다.
    private func backupIfNeeded() throws {
        let key = dataDir.path + "|" + dayKey()
        guard key != lastBackupKey else { return }
        lastBackupKey = key
        let fm = FileManager.default
        let dir = dataDir.appendingPathComponent("backups", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appendingPathComponent("data-\(dayKey()).json")
        if !fm.fileExists(atPath: target.path) {
            try fm.copyItem(at: dataURL, to: target)
        }
        let backups = try fm.contentsOfDirectory(atPath: dir.path).filter { $0.hasPrefix("data-") }.sorted()
        for old in backups.dropLast(14) { try? fm.removeItem(at: dir.appendingPathComponent(old)) }
    }

    /// 저장 폴더를 바꾼다. 새 폴더에 이미 data.json 이 있으면 그걸 불러오고, 없으면 지금 기록을 옮겨 쓴다.
    /// 실패하면 폴더를 바꾸지 않고 이유를 돌려준다.
    func changeDataDir(to dir: URL) -> String? {
        if !saveBlocked, !saveNow() {
            return "지금 기록을 저장하지 못해서 폴더를 바꾸지 않았어요. \(saveError ?? "")"
        }
        let old = dataDir, oldBlocked = saveBlocked, oldError = saveError
        dataDir = dir
        if FileManager.default.fileExists(atPath: dataURL.path) {
            load()
            if saveBlocked {
                dataDir = old
                load()
                return "그 폴더의 기록 파일을 읽지 못해서 폴더를 바꾸지 않았어요."
            }
        } else {
            saveBlocked = false
            if !saveNow() {
                dataDir = old
                saveBlocked = oldBlocked
                saveError = oldError
                return "새 폴더에 저장하지 못해서 폴더를 바꾸지 않았어요."
            }
        }
        UserDefaults.standard.set(dir.path, forKey: Self.dirKey)
        return nil
    }
}
