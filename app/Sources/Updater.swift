import AppKit

// 새 버전 확인과 버튼 하나로 업데이트.
// - 하루 한 번 깃허브의 app/VERSION (글자 몇 개)만 읽어 내 버전과 비교한다. 보내는 정보는 없다.
// - 업데이트: 이 앱이 들어 있는 저장소 폴더에서 git pull → build.sh → 새 버전으로 다시 켠다.
//   README 의 한 줄 명령(git clone)으로 설치한 경우에만 동작한다.

final class Updater: ObservableObject {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(String) // 새 버전 번호
        case updating
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var notes = "" // CHANGELOG 중 새 버전 부분

    private static let raw = "https://raw.githubusercontent.com/brightree/focus-guard/main/"
    private static let lastCheckKey = "lastUpdateCheck"
    private static let notifiedKey = "notifiedVersion"

    let current = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"

    /// 이 앱이 들어 있는 저장소 (…/focus-guard). 앱이 app/FocusGuard.app 에 있을 때만.
    var repoDir: URL? {
        let repo = Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent()
        return FileManager.default.fileExists(atPath: repo.appendingPathComponent(".git").path) ? repo : nil
    }

    var latest: String? {
        if case .available(let v) = state { return v }
        return nil
    }

    func start() {
        // 켤 때 한 번(하루가 지났으면), 그 뒤로는 한 시간마다 "하루 지났나"만 본다
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { self.checkIfDue() }
        let t = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
        t.tolerance = 600
    }

    private func checkIfDue() {
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        if Date().timeIntervalSince(last) >= 24 * 3600 { check() }
    }

    /// 지금 바로 확인 (설정의 "업데이트 확인" 버튼)
    func check() {
        guard state != .checking, state != .updating else { return }
        state = .checking
        fetch("app/VERSION") { [weak self] text in
            guard let self else { return }
            UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
            guard let remote = text?.trimmingCharacters(in: .whitespacesAndNewlines), !remote.isEmpty else {
                self.state = .failed("새 버전을 확인하지 못했어요. 인터넷 연결을 확인해 주세요.")
                return
            }
            guard Self.isNewer(remote, than: self.current) else {
                self.state = .upToDate
                return
            }
            self.state = .available(remote)
            self.fetch("CHANGELOG.md") { md in
                self.notes = md.map { Self.notes(in: $0, from: remote, to: self.current) } ?? ""
            }
            if UserDefaults.standard.string(forKey: Self.notifiedKey) != remote {
                UserDefaults.standard.set(remote, forKey: Self.notifiedKey)
                Store.shared.notify("🍅 새 버전 \(remote)이 나왔어요", "메뉴 막대 🍅 → 업데이트를 누르면 바로 설치돼요.")
            }
        }
    }

    /// 최신 코드를 받아 빌드하고, 성공하면 새 버전으로 다시 켠다. 실패하면 지금 버전 그대로 둔다.
    func update() {
        guard let repo = repoDir else {
            state = .failed("자동 업데이트는 README의 설치 명령으로 설치한 경우에만 돼요. README 명령을 다시 붙여넣어 주세요.")
            return
        }
        state = .updating
        Store.shared.saveNow()
        DispatchQueue.global(qos: .userInitiated).async {
            let (ok, log) = Self.shell("git pull -q && cd app && ./build.sh", in: repo)
            DispatchQueue.main.async {
                guard ok else {
                    self.state = .failed("업데이트하지 못했어요. 지금 버전은 그대로예요.\n" + log.suffix(400))
                    return
                }
                // 이 앱이 꺼진 뒤 새 앱을 켜도록 맡겨 두고 종료한다 (포트가 겹치지 않게)
                let app = Bundle.main.bundleURL.path
                _ = Self.shell("(sleep 1; open \"\(app)\") >/dev/null 2>&1 &", in: repo, wait: false)
                NSApp.terminate(nil)
            }
        }
    }

    // MARK: - 내부

    private func fetch(_ path: String, _ done: @escaping (String?) -> Void) {
        var req = URLRequest(url: URL(string: Self.raw + path)!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        req.setValue("no-cache", forHTTPHeaderField: "Cache-Control")
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            let ok = (resp as? HTTPURLResponse)?.statusCode == 200
            let text = ok ? data.flatMap { String(data: $0, encoding: .utf8) } : nil
            DispatchQueue.main.async { done(text) }
        }.resume()
    }

    @discardableResult
    private static func shell(_ command: String, in dir: URL, wait: Bool = true) -> (Bool, String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/zsh")
        p.arguments = ["-c", command]
        p.currentDirectoryURL = dir
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = pipe
        do { try p.run() } catch { return (false, error.localizedDescription) }
        guard wait else { return (true, "") }
        let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        p.waitUntilExit()
        return (p.terminationStatus == 0, out)
    }

    /// "1.10.0" > "1.9.2" 처럼 숫자 단위로 비교한다
    static func isNewer(_ a: String, than b: String) -> Bool {
        let x = a.split(separator: ".").map { Int($0) ?? 0 }, y = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }

    /// CHANGELOG 에서 "## 새 버전" 부터 "## 지금 버전" 직전까지 (건너뛴 버전이 있으면 모두)
    static func notes(in changelog: String, from latest: String, to current: String) -> String {
        var out: [Substring] = []
        var inside = false
        for line in changelog.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("## ") {
                let v = line.dropFirst(3).split(separator: " ").first.map(String.init) ?? ""
                if v == current || (!v.isEmpty && !isNewer(v, than: current)) { break }
                if v == latest || isNewer(latest, than: v) { inside = true }
            }
            if inside { out.append(line) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
