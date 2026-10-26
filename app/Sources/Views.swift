import ServiceManagement
import SwiftUI

// MARK: - 메뉴 막대 패널

struct PopoverView: View {
    @EnvironmentObject var store: Store
    var primary: () -> Void
    var togglePause: () -> Void
    var openApp: () -> Void
    var close: () -> Void
    @State private var text = ""
    @State private var saved = false
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .firstTextBaseline) {
                Text(store.phase.label + (store.isPaused ? " · 일시정지" : "")).foregroundStyle(.secondary)
                Spacer()
                if store.phase != .idle {
                    Text(fmtClock(store.remaining)).font(.title2.bold().monospacedDigit())
                }
            }
            if store.phase.isStudy, !store.timer.task.isEmpty {
                Text("📌 \(store.timer.task)").lineLimit(2)
            }

            // 진행 중: [일시정지/재개] [앱 열기] [중지] — 앞의 둘은 같은 너비, 중지는 가장 작게
            HStack {
                if store.phase == .idle {
                    Button(action: primary) { Text("🍅 시작").frame(maxWidth: .infinity) }
                        .buttonStyle(.borderedProminent)
                        .tint(.red)
                } else {
                    Button(action: togglePause) {
                        Label(store.isPaused ? "재개" : "일시정지", systemImage: store.isPaused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .help(store.phase == .focus ? "집중 중에는 일시정지해도 차단이 유지돼요" : "")
                }
                Button(action: openApp) { Text("앱 열기").frame(maxWidth: .infinity) }
                if store.phase != .idle {
                    Button(stopTitle, action: primary)
                }
            }
            .controlSize(.large)

            VStack(alignment: .leading, spacing: 4) {
                TextField("💭 나중에 할 것 적기 (Enter)", text: $text)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit {
                        guard !text.trimmingCharacters(in: .whitespaces).isEmpty, store.canPersist else { return }
                        store.addLater(text)
                        text = ""
                        saved = true
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { close() }
                    }
                if saved {
                    Text("✓ 적어뒀어요. 다시 집중!").font(.caption).foregroundStyle(.green)
                }
            }

            if let err = store.saveError {
                Text("⚠️ \(err)").font(.caption).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true)
            }

            if store.browserAccessDenied {
                VStack(alignment: .leading, spacing: 4) {
                    Text("⚠️ 브라우저 제어 권한이 꺼져 있어서 사이트 차단이 안 돼요.")
                        .font(.caption).fixedSize(horizontal: false, vertical: true)
                    Button("자동화 설정 열기") {
                        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
                    }
                    .controlSize(.small)
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .onAppear { DispatchQueue.main.async { focused = true } }
    }

    var stopTitle: String {
        switch store.phase {
        case .wrap: return "완료"
        default: return "중지"
        }
    }
}

// MARK: - 딴짓 경고 (집중 외 시간에 한 사이트를 오래 쓸 때)

struct WarnView: View {
    let min: Int
    let site: String
    var closeTab: () -> Void
    var keep: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Text("⏰").font(.system(size: 40))
            Text("\(site)를 \(min)분째 쓰고 있어요").font(.title3.bold())
            Text("지금 이게 정말 하려던 일인가요? 뽀모도로 하나만 시작해볼까요?")
                .foregroundStyle(.secondary).multilineTextAlignment(.center)
            HStack {
                Button("알고 계속 보기", action: keep)
                Button("이 탭 닫기", action: closeTab).keyboardShortcut(.defaultAction)
            }
            .controlSize(.large)
        }
        .padding(24)
        .frame(width: 380)
    }
}

// MARK: - 집중 시작

struct StartView: View {
    @EnvironmentObject var store: Store
    @State var task: String
    var close: () -> Void

    var body: some View {
        let s = store.settings
        VStack(alignment: .leading, spacing: 12) {
            Text("이번 \(s.focusMin)분 동안 무엇을 할까요?").font(.title3.bold())
            if !store.lastNote.isEmpty {
                Text("지난 정리 메모: \(store.lastNote)").font(.callout).foregroundStyle(.secondary)
            }
            TextField("구체적으로 한 줄 (예: pset1 3번 회귀 결과 해석)", text: $task)
                .textFieldStyle(.roundedBorder)
                .onSubmit(start)
            let picks = store.today.todos.filter { !$0.done && $0.kind != .other }.prefix(5)
            if !picks.isEmpty {
                Text("오늘 할 일에서 고르기").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(picks)) { item in
                        Button((item.kind == .must ? "🔥 " : "") + item.text) { task = item.text }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                    }
                }
            }
            Text("집중 \(s.focusMin)분 → 정리 \(s.wrapMin)분 → 휴식 \(s.breakMin)분 · 집중·정리 중에는 사이트가 차단돼요")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("취소", action: close).keyboardShortcut(.cancelAction)
                Button("🍅 집중 시작", action: start)
                    .keyboardShortcut(.defaultAction)
                    .disabled(task.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    func start() {
        guard !task.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        store.startFocus(task: task)
        close()
    }
}

// MARK: - 오늘 할 일 (아침 계획)

extension TodoKind {
    var title: String {
        switch self {
        case .must: return "오늘 반드시"
        case .nice: return "하면 좋은 일"
        case .other: return "기타 업무"
        }
    }
    var symbol: String {
        switch self {
        case .must: return "flame.fill"
        case .nice: return "hand.thumbsup.fill"
        case .other: return "paperclip"
        }
    }
    var color: Color {
        switch self {
        case .must: return .red
        case .nice: return .blue
        case .other: return .gray
        }
    }
    var placeholder: String {
        switch self {
        case .must: return "꼭 끝낼 일 추가 (1~3개 추천)"
        case .nice: return "하면 좋은 일 추가"
        case .other: return "기타 업무 추가"
        }
    }
}

struct PlanView: View {
    @EnvironmentObject var store: Store

    var body: some View {
        let todos = store.today.todos
        let doneCount = todos.filter(\.done).count
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(store.now.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ko_KR"))))
                            .font(.system(size: 24, weight: .bold))
                        Text(todos.isEmpty ? "오늘 할 일을 정해볼까요?" : "\(todos.count)개 중 \(doneCount)개 완료")
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    ProgressRing(progress: todos.isEmpty ? 0 : Double(doneCount) / Double(todos.count))
                }
                .padding(.bottom, 4)

                let carry = store.unfinishedFromBefore
                if todos.isEmpty && !carry.isEmpty {
                    HStack {
                        Image(systemName: "arrow.uturn.forward.circle.fill").foregroundStyle(.orange)
                        Text("지난번에 못 한 일 \(carry.count)개가 있어요")
                        Spacer()
                        Button("가져오기") { withAnimation { store.carryOver() } }
                    }
                    .padding(12)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.12)))
                }

                ForEach(TodoKind.allCases, id: \.self) { kind in
                    TodoSection(kind: kind, items: todos.filter { $0.kind == kind })
                }
            }
            .padding(20)
        }
        .frame(width: 480)
        .frame(minHeight: 520, idealHeight: 620)
    }
}

struct ProgressRing: View {
    let progress: Double
    var body: some View {
        ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 5)
            Circle()
                .trim(from: 0, to: progress)
                .stroke(Color.green, style: StrokeStyle(lineWidth: 5, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut, value: progress)
            Text("\(Int((progress * 100).rounded()))%").font(.caption.bold().monospacedDigit())
        }
        .frame(width: 48, height: 48)
    }
}

struct TodoSection: View {
    @EnvironmentObject var store: Store
    let kind: TodoKind
    let items: [TodoItem]
    @State private var draft = ""

    var body: some View {
        // 끝낸 일은 아래로
        let sorted = items.filter { !$0.done } + items.filter(\.done)
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                Image(systemName: kind.symbol).foregroundStyle(kind.color)
                Text(kind.title).font(.headline)
                Spacer()
                if !items.isEmpty {
                    Text("\(items.filter(\.done).count)/\(items.count)")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            .padding(.bottom, 8)

            ForEach(sorted) { item in
                TodoRow(item: item, color: kind.color)
                Divider().opacity(0.5)
            }

            HStack(spacing: 10) {
                Image(systemName: "plus").foregroundStyle(kind.color).frame(width: 20)
                TextField(kind.placeholder, text: $draft)
                    .textFieldStyle(.plain)
                    .onSubmit {
                        withAnimation { store.addTodo(draft, kind: kind) }
                        draft = ""
                    }
            }
            .padding(.vertical, 8)
        }
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 12).fill(.background.secondary))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2).fill(kind.color).frame(width: 4).padding(.vertical, 14)
        }
    }
}

struct TodoRow: View {
    @EnvironmentObject var store: Store
    let item: TodoItem
    let color: Color
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.easeInOut(duration: 0.2)) { store.toggleTodo(item.id) }
            } label: {
                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 18))
                    .foregroundStyle(item.done ? color : Color.secondary)
                    .frame(width: 20)
            }
            .buttonStyle(.plain)

            Text(item.text)
                .strikethrough(item.done)
                .foregroundStyle(item.done ? .secondary : .primary)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation { store.deleteTodo(item.id) }
            } label: {
                Image(systemName: "trash").foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .opacity(hover ? 1 : 0)
            .help("삭제")
        }
        .padding(.vertical, 7)
        .contentShape(Rectangle())
        .onHover { hover = $0 }
        .opacity(item.done ? 0.6 : 1)
    }
}

// MARK: - 정리 3분

struct WrapView: View {
    @EnvironmentObject var store: Store
    @State private var note = ""
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("📝 정리 시간").font(.title3.bold())
                Spacer()
                if store.phase == .wrap {
                    Text(fmtClock(store.remaining)).font(.title3.monospacedDigit()).foregroundStyle(.orange)
                }
            }
            if !store.timer.task.isEmpty {
                Text("📌 \(store.timer.task)").foregroundStyle(.secondary)
            }
            Text("어디까지 했고, 다음엔 뭘 하나요?").font(.headline)
            TextEditor(text: $note)
                .font(.body)
                .frame(height: 80)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .onChange(of: note) { _, new in store.saveNote(new) }

            let open = store.openLater
            Text("💭 나중에 할 것 \(open.count)개 — 처리한 건 체크").font(.headline)
            if open.isEmpty {
                Text("없음 👏").foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(open) { item in
                            Toggle(isOn: Binding(get: { item.done }, set: { _ in store.toggleLater(item.id) })) {
                                Text(item.text)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            HStack {
                Spacer()
                Button("정리 완료 → 휴식") {
                    store.saveNote(note)
                    store.finishWrap()
                    close()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { note = store.lastNote }
    }
}

// MARK: - 나중에 할 것 빠르게 적기 (⌥⇧L)

struct QuickCaptureView: View {
    @EnvironmentObject var store: Store
    @State private var text = ""
    @State private var saved = false
    var close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("💭 떠오른 생각을 적고 다시 공부로", text: $text)
                .textFieldStyle(.roundedBorder)
                .font(.title3)
                .onSubmit {
                    guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return close() }
                    guard store.canPersist else { return }
                    store.addLater(text)
                    text = ""
                    saved = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { close() }
                }
            if let err = store.saveError {
                Text("⚠️ 지금은 저장할 수 없어요. \(err)").font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(saved ? "✓ 적어뒀어요. 이제 내려놓고 다시 집중!" : "Enter 저장 · Esc 닫기 · 정리 시간에 다시 보여드려요")
                    .font(.caption)
                    .foregroundStyle(saved ? .green : .secondary)
            }
        }
        .padding(16)
        .frame(width: 460)
        .onExitCommand(perform: close)
    }
}

// MARK: - 포기하기 (30초 대기 + 문장 입력)

struct GiveUpView: View {
    @EnvironmentObject var store: Store
    @State private var phrase = ""
    var onGiveUp: () -> Void
    var close: () -> Void

    var body: some View {
        let target = store.settings.stopPhrase
        let matches = Self.normalize(phrase) == Self.normalize(target)
        let canGiveUp = matches
        VStack(alignment: .leading, spacing: 12) {
            Text("정말 그만둘까요?").font(.title3.bold())
            Text("하고 싶은 게 생겼다면 ⌥⇧L로 적어두고 계속해도 돼요. 그래도 그만두려면 아래 문장을 그대로 입력하세요.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 입력하면 사라지는 안내 글자 대신, 따라 칠 문장을 항상 보여준다
            Text(target).font(.headline).textSelection(.enabled)
            TextField("위 문장을 그대로 입력", text: $phrase)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if canGiveUp { giveUp() } }
            Text(phrase.isEmpty ? " " : (matches ? "✓ 일치해요" : "아직 달라요 (띄어쓰기·문장부호는 상관없어요)"))
                .font(.caption)
                .foregroundStyle(matches ? .green : .secondary)
            HStack {
                Spacer()
                // Enter 는 입력칸에서 포기를 처리하므로, 계속하기는 Esc 로 연결한다
                Button("계속 집중하기", action: close).keyboardShortcut(.cancelAction)
                Button("포기", action: giveUp).disabled(!canGiveUp)
            }
        }
        .padding(20)
        .frame(width: 440)
    }

    private func giveUp() {
        onGiveUp()
        close()
    }

    /// 비교할 때 띄어쓰기·문장부호·유니코드 조합 방식 차이는 무시한다
    static func normalize(_ s: String) -> String {
        s.precomposedStringWithCanonicalMapping.filter { !$0.isWhitespace && !$0.isPunctuation }
    }
}

// MARK: - 기록 (주간 띠 + 하루 상세)

private let weekCal: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.firstWeekday = 2 // 월요일 시작
    return c
}()

private let weekdaySymbols = ["일", "월", "화", "수", "목", "금", "토"]

struct DashboardView: View {
    @EnvironmentObject var store: Store
    var openPlan: () -> Void
    var openSettings: () -> Void
    var quit: () -> Void
    @State private var weekOffset = 0
    @State private var selected = dayKey()
    @State private var newLater = ""

    var body: some View {
        let dates = weekDates
        let secs = dates.map { store.studySec(for: dayKey($0)) }
        let sessions = dates.map { store.data.days[dayKey($0)]?.sessions ?? 0 }.reduce(0, +)
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Button("📋 오늘 할 일", action: openPlan)
                    Button("⚙︎ 설정", action: openSettings)
                    Spacer()
                    Button("종료", action: quit)
                }
                .controlSize(.large)

                HStack {
                    Button { changeWeek(-1) } label: { Image(systemName: "chevron.left") }
                    Text(weekTitle(dates)).font(.title3.bold())
                    Button { changeWeek(1) } label: { Image(systemName: "chevron.right") }
                        .disabled(weekOffset >= 0)
                    Spacer()
                    Text("이번 주 공부 \(fmtMinutes(secs.reduce(0, +))) · 🍅 \(sessions)개")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)

                Card(title: "") {
                    WeekChart(dates: dates, secs: secs, selected: $selected)
                }

                DayDetail(key: selected)

                laterCard
            }
            .padding(20)
        }
        .frame(minWidth: 620, minHeight: 700)
    }

    var weekDates: [Date] {
        let start = weekCal.dateInterval(of: .weekOfYear, for: store.now)!.start
        let monday = weekCal.date(byAdding: .day, value: 7 * weekOffset, to: start)!
        return (0..<7).map { weekCal.date(byAdding: .day, value: $0, to: monday)! }
    }

    func weekTitle(_ dates: [Date]) -> String {
        let f = { (d: Date) in "\(weekCal.component(.month, from: d))/\(weekCal.component(.day, from: d))" }
        return (weekOffset == 0 ? "이번 주 " : "") + "\(f(dates[0])) – \(f(dates[6]))"
    }

    func changeWeek(_ delta: Int) {
        weekOffset = min(0, weekOffset + delta)
        // 이번 주로 돌아오면 오늘, 지난 주면 그 주 월요일을 고른다
        selected = weekOffset == 0 ? dayKey(store.now) : dayKey(weekDates[0])
    }

    var laterCard: some View {
        Card(title: "💭 나중에 할 것") {
            HStack {
                TextField("새로 적기 (Enter)", text: $newLater)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { store.addLater(newLater); newLater = "" }
                Button("완료 항목 지우기") { store.clearDoneLater() }
            }
            let items = store.data.later.sorted { ($0.done ? 1 : 0, -$0.created.timeIntervalSince1970) < ($1.done ? 1 : 0, -$1.created.timeIntervalSince1970) }
            if items.isEmpty {
                Text("공부 중 떠오른 생각을 ⌥⇧L로 적으면 여기 모여요.").foregroundStyle(.secondary)
            }
            ForEach(items) { item in
                HStack(alignment: .top) {
                    Toggle("", isOn: Binding(get: { item.done }, set: { _ in store.toggleLater(item.id) }))
                        .labelsHidden()
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.text).strikethrough(item.done).foregroundStyle(item.done ? .secondary : .primary)
                        Text(item.created.formatted(date: .abbreviated, time: .shortened)
                             + (item.during.isEmpty ? "" : " · \"\(item.during)\" 하다가"))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button("삭제") { store.deleteLater(item.id) }.buttonStyle(.borderless).foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// 월~일 공부 시간 막대. 세로축은 1시간 단위 눈금, 맨 위는 가장 긴 날을 정시로 올림.
struct WeekChart: View {
    @EnvironmentObject var store: Store
    let dates: [Date]
    let secs: [Double]
    @Binding var selected: String
    private let chartH: CGFloat = 140

    var body: some View {
        let topHours = max(1, Int((secs.max() ?? 0) / 3600 - 0.0001) + 1)
        let scale = chartH / CGFloat(topHours * 3600)
        HStack(alignment: .top, spacing: 6) {
            // 세로축 라벨
            ZStack(alignment: .topTrailing) {
                ForEach(0...topHours, id: \.self) { h in
                    Text(h == 0 ? "0" : "\(h)h")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                        .offset(y: chartH - CGFloat(h * 3600) * scale + 18 - 7)
                }
            }
            .frame(width: 24, height: chartH + 18, alignment: .topTrailing)

            ZStack(alignment: .topLeading) {
                // 1시간 눈금선
                ForEach(0...topHours, id: \.self) { h in
                    Rectangle()
                        .fill(Color.secondary.opacity(h == 0 ? 0.4 : 0.15))
                        .frame(height: 1)
                        .offset(y: chartH - CGFloat(h * 3600) * scale + 18)
                }
                HStack(alignment: .bottom, spacing: 8) {
                    ForEach(dates.indices, id: \.self) { i in
                        dayColumn(i, scale: scale)
                    }
                }
            }
        }
    }

    func dayColumn(_ i: Int, scale: CGFloat) -> some View {
        let key = dayKey(dates[i])
        let isSel = key == selected
        let isFuture = dates[i] > store.now && key != dayKey(store.now)
        let sec = secs[i]
        return Button { selected = key } label: {
            VStack(spacing: 4) {
                Text(sec >= 60 ? shortTime(sec) : " ")
                    .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    .frame(height: 14)
                ZStack(alignment: .bottom) {
                    Color.clear.frame(height: chartH)
                    if sec >= 60 {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(Color.red.opacity(isSel ? 0.9 : 0.55))
                            .frame(height: CGFloat(sec) * scale)
                    }
                }
                Text("\(weekdaySymbols[weekCal.component(.weekday, from: dates[i]) - 1]) \(weekCal.component(.day, from: dates[i]))")
                    .font(.caption.weight(isSel ? .bold : .regular))
                    .foregroundStyle(isFuture ? .tertiary : (isSel ? .primary : .secondary))
            }
            .padding(.horizontal, 4)
            .padding(.bottom, 4)
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 8).fill(isSel ? Color.accentColor.opacity(0.15) : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(isFuture)
    }

    func shortTime(_ sec: Double) -> String {
        let m = Int((sec / 60).rounded())
        return m >= 60 ? "\(m / 60)h \(m % 60)m" : "\(m)m"
    }
}

/// 선택한 하루의 할 일, 한 일(정리 메모), 딴짓
struct DayDetail: View {
    @EnvironmentObject var store: Store
    let key: String

    var body: some View {
        let day = store.data.days[key] ?? DayStats()
        let isToday = key == dayKey(store.now)
        VStack(alignment: .leading, spacing: 12) {
            Text(title + (isToday ? " (오늘)" : "")).font(.title3.bold())
            HStack(spacing: 10) {
                Kpi(value: fmtMinutes(store.studySec(for: key)), label: "공부")
                Kpi(value: "\(day.sessions)", label: "완료한 뽀모도로")
                Kpi(value: fmtMinutes(day.distractTotal), label: "딴짓")
            }

            Card(title: "할 일") {
                if day.todos.isEmpty {
                    Text(isToday ? "메뉴 막대 🍅 → 오늘 할 일에서 적을 수 있어요." : "이 날은 적은 할 일이 없어요.")
                        .foregroundStyle(.secondary)
                }
                ForEach(TodoKind.allCases, id: \.self) { kind in
                    let items = day.todos.filter { $0.kind == kind }
                    if !items.isEmpty {
                        HStack(spacing: 6) {
                            Image(systemName: kind.symbol).foregroundStyle(kind.color)
                            Text(kind.title).font(.subheadline.bold())
                            Text("\(items.filter(\.done).count)/\(items.count)")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                        ForEach(items) { item in
                            HStack(spacing: 8) {
                                Image(systemName: item.done ? "checkmark.circle.fill" : "circle")
                                    .foregroundStyle(item.done ? kind.color : Color.secondary)
                                Text(item.text).strikethrough(item.done)
                                    .foregroundStyle(item.done ? .secondary : .primary)
                            }
                            .padding(.leading, 4)
                        }
                    }
                }
            }

            Card(title: "한 일") {
                if day.log.isEmpty {
                    Text("이 날은 뽀모도로 기록이 없어요.").foregroundStyle(.secondary)
                }
                ForEach(day.log) { l in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(l.done ? "🍅" : "✖️") \(l.end.formatted(date: .omitted, time: .shortened)) — \(l.task.isEmpty ? "(할 일 없음)" : l.task) \(l.done ? "(\(l.minutes ?? 0)분)" : "(포기)")")
                        if !l.note.isEmpty {
                            Text("📝 \(l.note)").font(.callout).foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }

            Card(title: "딴짓 사이트") {
                let entries = day.distractSec.sorted { $0.value > $1.value }
                if entries.isEmpty {
                    Text("딴짓 기록이 없어요 👏").foregroundStyle(.secondary)
                }
                let maxV = entries.first?.value ?? 1
                ForEach(entries, id: \.key) { site, sec in
                    HStack {
                        Text(site).frame(width: 130, alignment: .leading)
                        GeometryReader { g in
                            RoundedRectangle(cornerRadius: 3).fill(.secondary.opacity(0.5))
                                .frame(width: max(2, g.size.width * sec / maxV))
                        }
                        .frame(height: 10)
                        Text(fmtMinutes(sec)).monospacedDigit().foregroundStyle(.secondary).frame(width: 70, alignment: .trailing)
                    }
                }
                Text("연속 사용 경고 \(day.warnings)회 · 중도 포기 \(day.abandoned)회")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    var title: String {
        guard let d = dayKeyFormatter.date(from: key) else { return key }
        return d.formatted(.dateTime.month().day().weekday(.wide).locale(Locale(identifier: "ko_KR")))
    }
}

struct Kpi: View {
    let value: String
    let label: String
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value).font(.title2.bold().monospacedDigit())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

struct Card<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if !title.isEmpty { Text(title).font(.headline) }
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(RoundedRectangle(cornerRadius: 10).fill(.background.secondary))
    }
}

// MARK: - 설정

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @State private var s = Settings()
    @State private var sitesText = ""
    @State private var allowText = ""
    @State private var saved = false
    @State private var rejected: [String] = []
    var chooseFolder: () -> Void
    var revealFolder: () -> Void
    var toggleLogin: () -> Void
    var uninstall: () -> Void
    @State private var loginOn = SMAppService.mainApp.status == .enabled

    var body: some View {
        let locked = store.isBlocking
        VStack(alignment: .leading, spacing: 14) {
            Text("시간").font(.headline)
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 8) {
                NumberRow(label: "집중 (분)", value: $s.focusMin, range: Settings.focusRange)
                NumberRow(label: "정리 (분)", value: $s.wrapMin, range: Settings.wrapRange)
                NumberRow(label: "휴식 (분)", value: $s.breakMin, range: Settings.breakRange)
                NumberRow(label: "연속 사용 경고 (분)", value: $s.warnAfterMin, range: Settings.warnRange)
            }
            Button("기본값으로 (35 · 3 · 7)") {
                s.focusMin = 35
                s.wrapMin = 3
                s.breakMin = 7
            }
            .buttonStyle(.link)

            Text("포기할 때 입력할 문장").font(.headline)
            TextField("", text: $s.stopPhrase).textFieldStyle(.roundedBorder)

            Text("차단할 사이트 (한 줄에 하나, 하위 도메인 포함)").font(.headline)
            TextEditor(text: $sitesText)
                .font(.body.monospaced())
                .frame(height: 120)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            Text("허용할 사이트 (위 목록의 하위 도메인이어도 막지 않음)").font(.headline)
            TextEditor(text: $allowText)
                .font(.body.monospaced())
                .frame(height: 44)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))

            HStack {
                Button("저장") {
                    s.sites = sitesText.split(whereSeparator: \.isNewline).map(String.init)
                    s.allowSites = allowText.split(whereSeparator: \.isNewline).map(String.init)
                    rejected = store.updateSettings(s)
                    load()
                    saved = true
                }
                .keyboardShortcut(.defaultAction)
                .disabled(locked)
                if saved { Text("저장됨 ✓").foregroundStyle(.secondary) }
                if locked { Text("집중·정리 중에는 바꿀 수 없어요").foregroundStyle(.red) }
            }
            if !rejected.isEmpty {
                Text("사이트로 인식하지 못해 뺐어요: \(rejected.joined(separator: ", "))")
                    .font(.caption).foregroundStyle(.red)
            }

            Divider()
            Toggle("로그인 시 자동 실행 (꺼져 있으면 사이트 차단도 안 돼요)", isOn: Binding(
                get: { loginOn },
                set: { _ in
                    toggleLogin()
                    loginOn = SMAppService.mainApp.status == .enabled
                }))

            Divider()
            Text("기록 저장 위치").font(.headline)
            Text(store.dataDir.path).font(.caption.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
            Text("매일 자동으로 백업해요. 앱을 다시 빌드하거나 업데이트해도 기록은 그대로예요.")
                .font(.caption)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("다른 폴더 선택…", action: chooseFolder)
                Button("Finder에서 보기", action: revealFolder)
            }

            Divider()
            Button("Focus Guard 삭제…", role: .destructive, action: uninstall)
                .disabled(locked)
        }
        .padding(20)
        .frame(width: 480)
        .onAppear(perform: load)
    }

    func load() {
        s = store.settings
        sitesText = s.sites.joined(separator: "\n")
        allowText = s.allowSites.joined(separator: "\n")
    }
}

struct NumberRow: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var body: some View {
        GridRow {
            Text(label)
            HStack(spacing: 4) {
                TextField("", value: Binding(get: { value }, set: { value = min(max($0, range.lowerBound), range.upperBound) }),
                          format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                Stepper("", value: $value, in: range).labelsHidden()
            }
        }
    }
}
