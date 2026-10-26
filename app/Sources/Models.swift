import Foundation

// 모든 기록은 data.json 한 파일에 저장된다. 필드가 추가돼도 옛 파일을 읽을 수 있도록
// 디코딩은 전부 decodeIfPresent + 기본값으로 한다.

enum Phase: String, Codable {
    case idle, focus, wrap
    case rest = "break"

    var isStudy: Bool { self == .focus || self == .wrap }
    var label: String {
        switch self {
        case .idle: return "대기 중"
        case .focus: return "집중 중"
        case .wrap: return "정리 중"
        case .rest: return "휴식 중"
        }
    }
    var icon: String {
        switch self {
        case .idle, .focus: return "🍅"
        case .wrap: return "📝"
        case .rest: return "☕"
        }
    }
}

struct Settings: Codable, Equatable {
    var focusMin = 35
    var wrapMin = 3
    var breakMin = 7
    var warnAfterMin = 10 // 집중 외 시간에 한 사이트를 연속으로 이만큼 쓰면 경고
    var stopPhrase = "일해야 졸업하지"
    var sites = ["youtube.com", "linkedin.com", "instagram.com", "facebook.com", "x.com", "twitter.com", "reddit.com", "netflix.com"]
    /// 차단 목록의 하위 도메인이어도 막지 않는 사이트 (예: 공부하며 듣는 유튜브 뮤직)
    var allowSites = ["music.youtube.com"]
    /// 집중·정리 중 맨 앞 앱과 사이트(도메인)를 통계용으로 기록할지
    var trackStudyUsage = true

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = Settings()
        focusMin = try c.decodeIfPresent(Int.self, forKey: .focusMin) ?? d.focusMin
        wrapMin = try c.decodeIfPresent(Int.self, forKey: .wrapMin) ?? d.wrapMin
        breakMin = try c.decodeIfPresent(Int.self, forKey: .breakMin) ?? d.breakMin
        warnAfterMin = try c.decodeIfPresent(Int.self, forKey: .warnAfterMin) ?? d.warnAfterMin
        stopPhrase = try c.decodeIfPresent(String.self, forKey: .stopPhrase) ?? d.stopPhrase
        sites = try c.decodeIfPresent([String].self, forKey: .sites) ?? d.sites
        allowSites = try c.decodeIfPresent([String].self, forKey: .allowSites) ?? d.allowSites
        trackStudyUsage = try c.decodeIfPresent(Bool.self, forKey: .trackStudyUsage) ?? d.trackStudyUsage
        self = clamped()
    }

    static let focusRange = 1...180
    static let wrapRange = 1...30
    static let breakRange = 1...60
    static let warnRange = 1...120

    /// 모든 숫자 설정을 허용 범위 안으로 맞춘다 (화면 입력, 저장, 파일 읽기 모두 여기를 거친다)
    func clamped() -> Settings {
        func clamp(_ v: Int, _ r: ClosedRange<Int>) -> Int { min(max(v, r.lowerBound), r.upperBound) }
        var s = self
        s.focusMin = clamp(focusMin, Self.focusRange)
        s.wrapMin = clamp(wrapMin, Self.wrapRange)
        s.breakMin = clamp(breakMin, Self.breakRange)
        s.warnAfterMin = clamp(warnAfterMin, Self.warnRange)
        return s
    }
}

struct TimerState: Codable {
    var phase: Phase = .idle
    var endTime: Date?
    var pausedRemaining: TimeInterval? // 초
    var startedAt: Date? // 현재 공부 구간 시작 (공부 시간 누적용)
    var task = ""
    var lastLogDay: String? // 마지막으로 끝난 집중 세션이 기록된 날 (정리 메모를 붙일 곳)
    var lastLogID: UUID?

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        lastLogDay = try c.decodeIfPresent(String.self, forKey: .lastLogDay)
        lastLogID = try c.decodeIfPresent(UUID.self, forKey: .lastLogID)
        phase = try c.decodeIfPresent(Phase.self, forKey: .phase) ?? .idle
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime)
        pausedRemaining = try c.decodeIfPresent(TimeInterval.self, forKey: .pausedRemaining)
        startedAt = try c.decodeIfPresent(Date.self, forKey: .startedAt)
        task = try c.decodeIfPresent(String.self, forKey: .task) ?? ""
    }
}

struct LogEntry: Codable, Identifiable {
    var id = UUID()
    var task: String
    var minutes: Int? // nil이면 중도 포기
    var end: Date
    var done: Bool
    var note = ""
}

enum TodoKind: String, Codable, CaseIterable {
    case must, nice, other
}

struct TodoItem: Codable, Identifiable {
    var id = UUID()
    var text: String
    var kind: TodoKind
    var done = false
}

struct DayStats: Codable {
    var todos: [TodoItem] = []
    var focusSec: Double = 0
    var sessions = 0
    var abandoned = 0
    var warnings = 0
    var distractSec: [String: Double] = [:]
    var studyApps: [String: Double] = [:] // 집중·정리 중 맨 앞에 있던 앱 → 초
    var studySites: [String: Double] = [:] // 집중·정리 중 본 사이트(도메인) → 초
    var log: [LogEntry] = []

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        todos = try c.decodeIfPresent([TodoItem].self, forKey: .todos) ?? []
        focusSec = try c.decodeIfPresent(Double.self, forKey: .focusSec) ?? 0
        sessions = try c.decodeIfPresent(Int.self, forKey: .sessions) ?? 0
        abandoned = try c.decodeIfPresent(Int.self, forKey: .abandoned) ?? 0
        warnings = try c.decodeIfPresent(Int.self, forKey: .warnings) ?? 0
        distractSec = try c.decodeIfPresent([String: Double].self, forKey: .distractSec) ?? [:]
        studyApps = try c.decodeIfPresent([String: Double].self, forKey: .studyApps) ?? [:]
        studySites = try c.decodeIfPresent([String: Double].self, forKey: .studySites) ?? [:]
        log = try c.decodeIfPresent([LogEntry].self, forKey: .log) ?? []
    }

    var distractTotal: Double { distractSec.values.reduce(0, +) }
}

struct LaterItem: Codable, Identifiable {
    var id = UUID()
    var text: String
    var created: Date
    var during: String // 어떤 공부 중에 떠오른 생각인지
    var done = false
}

struct DataFile: Codable {
    var version = 1
    var settings = Settings()
    var timer = TimerState()
    var days: [String: DayStats] = [:]
    var later: [LaterItem] = []
    var planShownDay = "" // 아침 계획 창을 마지막으로 자동으로 띄운 날

    init() {}
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        version = try c.decodeIfPresent(Int.self, forKey: .version) ?? 1
        settings = try c.decodeIfPresent(Settings.self, forKey: .settings) ?? Settings()
        timer = try c.decodeIfPresent(TimerState.self, forKey: .timer) ?? TimerState()
        days = try c.decodeIfPresent([String: DayStats].self, forKey: .days) ?? [:]
        later = try c.decodeIfPresent([LaterItem].self, forKey: .later) ?? []
        planShownDay = try c.decodeIfPresent(String.self, forKey: .planShownDay) ?? ""
    }
}

/// "yyyy-MM-dd" (기기 시간대 기준). 자주 불리므로 포매터는 하나만 만든다.
let dayKeyFormatter: DateFormatter = {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f
}()

let madeBy = "Made by Anonymous, KAIST IS"

func dayKey(_ d: Date = Date()) -> String { dayKeyFormatter.string(from: d) }

func fmtMinutes(_ sec: Double) -> String {
    let m = Int((sec / 60).rounded())
    return m >= 60 ? "\(m / 60)시간 \(m % 60)분" : "\(m)분"
}

func fmtClock(_ sec: Double) -> String {
    let s = max(0, Int(sec.rounded()))
    return String(format: "%02d:%02d", s / 60, s % 60)
}
