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

    /// 단계가 바뀔 때 UI가 창을 띄우도록 알려준다 (이전 단계, 새 단계)
    var onPhaseChange: ((Phase, Phase) -> Void)?

    private var streak: (site: String, sec: Double, lastSeen: Date, warnedMin: Int)?
    private var lastTickAt: Date?
    private var saveWork: DispatchWorkItem?
    /// data.json 이 있는데 읽지 못했으면(예: 클라우드 파일이 아직 안 내려받아짐) 덮어쓰지 않도록 저장을 막는다
    private var saveBlocked = false
    /// 1초 타이머마다 불린다 (브라우저 감시 등)
    var onSecond: (() -> Void)?

    private static let dirKey = "dataDir"
    private static let streakGapSec: Double = 180

    private init() {
        if let path = UserDefaults.standard.string(forKey: Self.dirKey) {
            dataDir = URL(fileURLWithPath: path)
        } else {
            dataDir = Self.googleDriveDir() ?? Self.localDir
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
    var liveStudySec: Double { today.focusSec + pendingStudySec() }

    func studySec(for key: String) -> Double {
        let base = data.days[key]?.focusSec ?? 0
        return key == dayKey(now) ? base + pendingStudySec() : base
    }

    private func pendingStudySec() -> Double {
        guard phase.isStudy, let start = data.timer.startedAt else { return 0 }
        let until = min(now, data.timer.endTime ?? now)
        return max(0, until.timeIntervalSince(start))
    }

    // MARK: - 변경 헬퍼

    private func mutate(_ f: (inout DataFile) -> Void) {
        f(&data)
        scheduleSave()
    }

    private func updateToday(_ f: (inout DayStats) -> Void) {
        mutate { d in
            let k = dayKey()
            var day = d.days[k] ?? DayStats()
            f(&day)
            d.days[k] = day
        }
    }

    private func flushStudyTime() {
        let sec = pendingStudySec()
        if sec > 0 { updateToday { $0.focusSec += sec } }
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
            let t = timer.task, m = settings.focusMin
            updateToday { d in
                d.sessions += 1
                d.log.append(LogEntry(task: t, minutes: m, end: Date(), done: true))
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

    func saveNote(_ note: String) {
        updateToday { d in
            guard !d.log.isEmpty else { return }
            d.log[d.log.count - 1].note = note.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    var lastNote: String { today.log.last?.note ?? "" }

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
        onSecond?()
    }

    // MARK: - 설정

    func updateSettings(_ s: Settings) {
        var s = s
        s.focusMin = max(1, s.focusMin)
        s.wrapMin = max(1, s.wrapMin)
        s.breakMin = max(1, s.breakMin)
        s.sites = Array(NSOrderedSet(array: s.sites.compactMap(Self.normalizeSite))) as? [String] ?? []
        if s.stopPhrase.trimmingCharacters(in: .whitespaces).isEmpty { s.stopPhrase = Settings().stopPhrase }
        mutate { $0.settings = s }
    }

    static func normalizeSite(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        for p in ["https://", "http://", "www."] where s.hasPrefix(p) { s.removeFirst(p.count) }
        if let slash = s.firstIndex(of: "/") { s = String(s[..<slash]) }
        return s.isEmpty ? nil : s
    }

    // MARK: - 나중에 할 것

    func addLater(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
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

        updateToday { $0.distractSec[site, default: 0] += delta }
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

    /// Google Drive for desktop 이 설치돼 있으면 "내 드라이브/FocusGuard" 를 돌려준다.
    static func googleDriveDir() -> URL? {
        let cloud = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/CloudStorage")
        guard let accounts = try? FileManager.default.contentsOfDirectory(at: cloud, includingPropertiesForKeys: nil) else { return nil }
        for acc in accounts where acc.lastPathComponent.hasPrefix("GoogleDrive-") {
            for name in ["My Drive", "내 드라이브"] {
                let root = acc.appendingPathComponent(name, isDirectory: true)
                if FileManager.default.fileExists(atPath: root.path) {
                    return root.appendingPathComponent("FocusGuard", isDirectory: true)
                }
            }
        }
        return nil
    }

    var dataURL: URL { dataDir.appendingPathComponent("data.json") }
    var isOnGoogleDrive: Bool { dataDir.path.contains("/CloudStorage/GoogleDrive-") }

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
            return
        }
        guard let raw = try? Data(contentsOf: dataURL) else {
            saveBlocked = true
            data = DataFile()
            notify("기록 파일을 읽지 못했어요", "\(dataURL.path)\n원본을 지키기 위해 저장을 멈췄어요. 파일을 확인한 뒤 앱을 다시 켜주세요.")
            return
        }
        do {
            data = try Self.decoder.decode(DataFile.self, from: raw)
        } catch {
            // 읽을 수 없는 파일은 지우지 않고 옆에 보관한 뒤 새로 시작한다.
            let bad = dataDir.appendingPathComponent("data.unreadable-\(Int(Date().timeIntervalSince1970)).json")
            try? FileManager.default.moveItem(at: dataURL, to: bad)
            data = DataFile()
        }
    }

    /// 변경이 계속 들어와도 최대 1초 안에 한 번은 저장된다.
    private func scheduleSave() {
        guard saveWork == nil else { return }
        let work = DispatchWorkItem { [weak self] in self?.saveNow() }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: work)
    }

    func saveNow() {
        saveWork?.cancel()
        saveWork = nil
        guard !saveBlocked else { return }
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: dataDir, withIntermediateDirectories: true)
            try Self.encoder.encode(data).write(to: dataURL, options: .atomic)
            try backupIfNeeded()
        } catch {
            NSLog("FocusGuard: save failed: \(error)")
        }
    }

    /// 하루 한 번 backups/data-YYYY-MM-DD.json 을 남기고 최근 14개만 유지한다.
    private func backupIfNeeded() throws {
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
    func changeDataDir(to dir: URL) {
        saveNow()
        dataDir = dir
        UserDefaults.standard.set(dir.path, forKey: Self.dirKey)
        if FileManager.default.fileExists(atPath: dataURL.path) {
            load()
        } else {
            saveNow()
        }
    }
}
