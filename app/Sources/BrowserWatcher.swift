import AppKit

// 맨 앞 브라우저의 현재 탭 주소를 1초마다 확인한다 (AppleScript, Store 의 1초 타이머에서 호출).
// - 집중·정리 중: 분산 사이트면 그 탭을 앱의 차단 페이지로 바꾼다.
// - 그 외: 딴짓 시간을 기록하고, 한 사이트를 오래 쓰면 경고한다.
// 브라우저가 맨 앞에 없으면 아무것도 하지 않는다.

final class BrowserWatcher {
    /// 번들 ID → 그 브라우저에서 "지금 보는 탭"을 부르는 이름
    static let browsers: [String: String] = [
        "com.google.Chrome": "active tab",
        "com.brave.Browser": "active tab",
        "com.microsoft.edgemac": "active tab",
        "company.thebrowser.Browser": "active tab",
        "com.apple.Safari": "current tab",
    ]

    private let store = Store.shared
    private var compiled: [String: NSAppleScript] = [:]
    /// (분, 사이트, 브라우저 번들 ID)
    var onWarn: ((Int, String, String) -> Void)?

    func tick() {
        let userActive = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                 eventType: CGEventType(rawValue: ~0)!) < 60
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let tabRef = Self.browsers[bid],
              let url = run("tell application id \"\(bid)\" to get URL of \(tabRef) of front window"),
              let site = siteOf(url)
        else {
            _ = store.reportBrowsing(site: nil, active: userActive)
            return
        }
        if store.isBlocking {
            redirect(bid: bid, target: "\(tabRef) of front window", url: url)
            return
        }
        if let warn = store.reportBrowsing(site: site, active: userActive) {
            onWarn?(warn.min, warn.site, bid)
        }
    }

    /// 집중을 시작할 때 이미 열려 있던 분산 사이트 탭을 모두 차단 페이지로 바꾼다 (실행 중인 브라우저만).
    func sweepAllTabs() {
        let running = Set(NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier))
        for bid in Self.browsers.keys where running.contains(bid) {
            let src = """
            tell application id "\(bid)"
              set out to {}
              repeat with wi from 1 to count of windows
                repeat with ti from 1 to count of tabs of window wi
                  set end of out to (wi as text) & tab & (ti as text) & tab & (URL of tab ti of window wi)
                end repeat
              end repeat
              set AppleScript's text item delimiters to linefeed
              return out as text
            end tell
            """
            guard let list = run(src) else { continue }
            for line in list.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let wi = Int(parts[0]), let ti = Int(parts[1]), siteOf(parts[2]) != nil else { continue }
                redirect(bid: bid, target: "tab \(ti) of window \(wi)", url: parts[2])
            }
        }
    }

    /// 경고 창에서 "탭 닫기"를 눌렀을 때
    func closeFrontTab(bid: String) {
        guard let tabRef = Self.browsers[bid] else { return }
        _ = run("tell application id \"\(bid)\" to close \(tabRef) of front window", cache: false)
    }

    // MARK: - 내부

    private func siteOf(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return store.settings.sites.first { host == $0 || host.hasSuffix("." + $0) }
    }

    private func redirect(bid: String, target: String, url: String) {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        let blocked = "http://127.0.0.1:\(SERVER_PORT)/blocked#\(encoded)"
        _ = run("tell application id \"\(bid)\" to set URL of \(target) to \"\(blocked)\"", cache: false)
    }

    /// AppleScript 실행. 권한 거부(-1743)면 Store에 표시해 패널에서 안내한다.
    private func run(_ source: String, cache: Bool = true) -> String? {
        let full = "with timeout of 2 seconds\n\(source)\nend timeout"
        let script: NSAppleScript?
        if cache {
            if compiled[full] == nil { compiled[full] = NSAppleScript(source: full) }
            script = compiled[full]
        } else {
            script = NSAppleScript(source: full)
        }
        var err: NSDictionary?
        let result = script?.executeAndReturnError(&err)
        if let err {
            if (err[NSAppleScript.errorNumber] as? Int) == -1743, !store.browserAccessDenied {
                store.browserAccessDenied = true
            }
            return nil
        }
        if store.browserAccessDenied { store.browserAccessDenied = false }
        return result?.stringValue
    }
}
