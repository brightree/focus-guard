import AppKit

// 맨 앞 브라우저의 현재 탭 주소를 1초마다 확인한다 (AppleScript, Store 의 1초 타이머에서 호출).
// - 집중·정리 중: 분산 사이트면 그 탭을 앱의 차단 페이지로 바꾼다.
// - 그 외: 딴짓 시간을 기록하고, 한 사이트를 오래 쓰면 경고한다.
// 브라우저가 맨 앞에 없으면 아무것도 하지 않는다.
// AppleScript 는 메인 스레드에서 동기로 돈다. 스크립트마다 2초 제한이 있고, 전체 탭 훑기는 브라우저당 최대 2번만 실행한다.

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
    /// 자동화 권한이 거부된 브라우저들 (브라우저마다 따로 관리)
    private var denied: Set<String> = []
    /// (분, 사이트, 브라우저 번들 ID)
    var onWarn: ((Int, String, String) -> Void)?

    func tick() {
        let userActive = CGEventSource.secondsSinceLastEventType(.combinedSessionState,
                                                                 eventType: CGEventType(rawValue: ~0)!) < 60
        guard let bid = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              let url = frontURL(bid),
              let site = siteOf(url)
        else {
            _ = store.reportBrowsing(site: nil, active: userActive)
            return
        }
        if store.isBlocking {
            _ = run(bid, "tell application id \"\(bid)\" to set URL of \(Self.browsers[bid]!) of front window to \"\(blockedURL(url))\"",
                    cache: false)
            return
        }
        if let warn = store.reportBrowsing(site: site, active: userActive) {
            onWarn?(warn.min, warn.site, bid)
        }
    }

    /// 집중을 시작할 때 이미 열려 있던 분산 사이트 탭을 모두 차단 페이지로 바꾼다 (실행 중인 브라우저만).
    /// 브라우저마다 "목록 읽기" 한 번, "한꺼번에 바꾸기" 한 번으로 끝낸다.
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
            guard let list = run(bid, src) else { continue }
            var sets: [String] = []
            for line in list.split(separator: "\n") {
                let parts = line.split(separator: "\t", maxSplits: 2).map(String.init)
                guard parts.count == 3, let wi = Int(parts[0]), let ti = Int(parts[1]), siteOf(parts[2]) != nil else { continue }
                sets.append("  set URL of tab \(ti) of window \(wi) to \"\(blockedURL(parts[2]))\"")
            }
            if !sets.isEmpty {
                _ = run(bid, "tell application id \"\(bid)\"\n\(sets.joined(separator: "\n"))\nend tell", cache: false)
            }
        }
    }

    /// 경고 창에서 "탭 닫기"를 눌렀을 때. 그 사이 다른 탭으로 옮겼다면 엉뚱한 탭을 닫지 않도록 아무것도 하지 않는다.
    func closeFrontTab(bid: String, ifStillOn site: String) {
        guard let url = frontURL(bid), siteOf(url) == site, let tabRef = Self.browsers[bid] else { return }
        _ = run(bid, "tell application id \"\(bid)\" to close \(tabRef) of front window", cache: false)
    }

    // MARK: - 내부

    private func frontURL(_ bid: String) -> String? {
        guard let tabRef = Self.browsers[bid] else { return nil }
        return run(bid, "tell application id \"\(bid)\" to get URL of \(tabRef) of front window")
    }

    private func siteOf(_ url: String) -> String? {
        guard let host = URL(string: url)?.host?.lowercased() else { return nil }
        return store.settings.sites.first { host == $0 || host.hasSuffix("." + $0) }
    }

    /// 원래 주소는 # 뒤에 넣는다 (서버로는 보내지지 않음). 영숫자 외에는 모두 인코딩해 따옴표가 섞일 수 없다.
    private func blockedURL(_ url: String) -> String {
        let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? ""
        return "http://127.0.0.1:\(SERVER_PORT)/blocked#\(encoded)"
    }

    /// AppleScript 실행. 권한 거부(-1743)는 브라우저별로 기록해 패널에서 안내한다.
    private func run(_ bid: String, _ source: String, cache: Bool = true) -> String? {
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
            if (err[NSAppleScript.errorNumber] as? Int) == -1743 { denied.insert(bid) }
        } else {
            denied.remove(bid)
        }
        if store.browserAccessDenied != !denied.isEmpty { store.browserAccessDenied = !denied.isEmpty }
        return err == nil ? result?.stringValue : nil
    }
}
