import Foundation
import Network

// 차단 페이지를 보여주는 아주 작은 HTTP 서버. 127.0.0.1 에서만 열린다.
//   GET  /blocked         → 차단 페이지 (브라우저 감시가 분산 사이트 탭을 여기로 보낸다)
//   GET  /status          → 현재 상태 (차단 여부, 남은 시간, 할 일) — 차단 페이지가 읽는다
//   POST /later {text}    → 나중에 할 것 추가

let SERVER_PORT: UInt16 = 47321

final class StateServer {
    private var listener: NWListener?
    private let store = Store.shared

    func start() {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: SERVER_PORT)!)
        params.allowLocalEndpointReuse = true
        do {
            listener = try NWListener(using: params)
        } catch {
            NSLog("FocusGuard: listen failed: \(error)")
            return
        }
        listener?.newConnectionHandler = { [weak self] conn in
            conn.start(queue: .main)
            self?.receive(conn, buffer: Data())
        }
        listener?.start(queue: .main)
    }

    private func receive(_ conn: NWConnection, buffer: Data) {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buf = buffer
            if let data { buf.append(data) }
            if let (headers, body) = Self.split(buf), body.count >= Self.contentLength(headers) {
                self.handle(conn, headers: headers, body: body)
            } else if isComplete || error != nil || buf.count > 1_000_000 {
                conn.cancel()
            } else {
                self.receive(conn, buffer: buf)
            }
        }
    }

    private static func split(_ data: Data) -> (String, Data)? {
        guard let range = data.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        return (String(decoding: data[..<range.lowerBound], as: UTF8.self), Data(data[range.upperBound...]))
    }

    private static func header(_ name: String, in lines: [Substring]) -> String? {
        for line in lines.dropFirst() {
            let parts = line.split(separator: ":", maxSplits: 1)
            if parts.count == 2, parts[0].lowercased() == name { return parts[1].trimmingCharacters(in: .whitespaces) }
        }
        return nil
    }

    private static func contentLength(_ headers: String) -> Int {
        for line in headers.split(separator: "\r\n") where line.lowercased().hasPrefix("content-length:") {
            return Int(line.split(separator: ":", maxSplits: 1)[1].trimmingCharacters(in: .whitespaces)) ?? 0
        }
        return 0
    }

    private func handle(_ conn: NWConnection, headers: String, body: Data) {
        let lines = headers.split(separator: "\r\n")
        let requestLine = String(lines.first ?? "")
        // 다른 웹사이트가 이 서버를 부르지 못하게 한다:
        // Host 가 정확히 우리 주소가 아니면 거부(DNS rebinding 방지), Origin 이 있으면 우리 주소만 허용(CSRF 방지).
        let host = Self.header("host", in: lines)
        let origin = Self.header("origin", in: lines)
        guard host == "127.0.0.1:\(SERVER_PORT)", origin == nil || origin == "http://127.0.0.1:\(SERVER_PORT)" else {
            send(conn, status: "403 Forbidden", type: "text/plain", body: Data())
            return
        }
        let json = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
        var status = "200 OK"
        var out: [String: Any] = [:]

        if requestLine.hasPrefix("GET /blocked") {
            send(conn, status: status, type: "text/html", body: Data(blockedPageHTML.utf8))
            return
        } else if requestLine.hasPrefix("GET /status") {
            out = statusJSON()
        } else if requestLine.hasPrefix("POST /later") {
            store.addLater(json["text"] as? String ?? "")
            out = statusJSON()
        } else {
            status = "404 Not Found"
        }

        let payload = (try? JSONSerialization.data(withJSONObject: out)) ?? Data("{}".utf8)
        send(conn, status: status, type: "application/json", body: payload)
    }

    private func send(_ conn: NWConnection, status: String, type: String, body: Data) {
        var resp = Data(("HTTP/1.1 \(status)\r\nContent-Type: \(type); charset=utf-8\r\n"
            + "Content-Length: \(body.count)\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n").utf8)
        resp.append(body)
        conn.send(content: resp, completion: .contentProcessed { _ in conn.cancel() })
    }

    private func statusJSON() -> [String: Any] {
        let t = store.timer
        return [
            "phase": t.phase.rawValue,
            "block": store.isBlocking,
            "paused": store.isPaused,
            "remainingSec": store.phase == .idle ? 0 : Int(store.remaining.rounded()),
            "task": t.task,
        ]
    }
}
