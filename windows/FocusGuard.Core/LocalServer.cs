using System.Net;
using System.Net.Sockets;
using System.Text;
using System.Text.Json;

namespace FocusGuard.Core;

/// 차단 페이지를 보여주는 아주 작은 HTTP 서버. 127.0.0.1 에서만 열린다 (맥 앱과 같은 규칙).
///   GET  /blocked       → 차단 페이지
///   GET  /status        → 현재 상태 (차단 여부, 남은 시간, 할 일) — 차단 페이지가 읽는다
///   POST /later {text}  → 나중에 할 것 추가
/// 요청은 백그라운드 스레드에서 받고, Store 는 onUi 로 화면 스레드에서만 만진다.
public sealed class LocalServer : IDisposable
{
    public const int Port = 47321;
    const int MaxBody = 64 * 1024;

    readonly Store store;
    readonly Func<Func<object?>, object?> onUi;
    readonly string closeShortcut;
    TcpListener? listener;
    volatile bool running;
    int port = Port;

    public bool IsListening => running;

    public LocalServer(Store store, Func<Func<object?>, object?> onUi, string closeShortcut = "Ctrl+W")
    {
        this.store = store; this.onUi = onUi; this.closeShortcut = closeShortcut;
    }

    public bool Start(int port = Port)
    {
        this.port = port;
        try
        {
            listener = new TcpListener(IPAddress.Loopback, port);
            listener.Start();
        }
        catch { return false; }
        running = true;
        new Thread(AcceptLoop) { IsBackground = true, Name = "FocusGuard server" }.Start();
        return true;
    }

    void AcceptLoop()
    {
        while (running)
        {
            TcpClient c;
            try { c = listener!.AcceptTcpClient(); } catch { break; }
            ThreadPool.QueueUserWorkItem(_ => Serve(c));
        }
    }

    void Serve(TcpClient c)
    {
        using (c)
        {
            try
            {
                c.ReceiveTimeout = 5000; // 요청을 끝내지 않고 붙잡고 있는 연결은 5초 뒤 끊는다
                c.SendTimeout = 5000;
                var stream = c.GetStream();
                var (status, type, body) = Handle(ReadRequest(stream));
                var head = $"HTTP/1.1 {status}\r\nContent-Type: {type}; charset=utf-8\r\nContent-Length: {body.Length}\r\nCache-Control: no-store\r\nConnection: close\r\n\r\n";
                stream.Write(Encoding.ASCII.GetBytes(head));
                stream.Write(body);
            }
            catch { /* 연결 문제는 무시 */ }
        }
    }

    internal sealed record Request(string? Line, List<string> Headers, byte[] Body, string? Error);

    /// 머리글을 읽고, Content-Length 만큼 본문을 읽는다. 잘못된 요청이면 Error.
    internal static Request ReadRequest(Stream s)
    {
        var buf = new MemoryStream();
        var one = new byte[4096];
        int headerEnd = -1;
        while (headerEnd < 0)
        {
            var n = s.Read(one, 0, one.Length);
            if (n <= 0) return new Request(null, new(), Array.Empty<byte>(), "400 Bad Request");
            buf.Write(one, 0, n);
            headerEnd = IndexOf(buf.GetBuffer(), (int)buf.Length, "\r\n\r\n"u8);
            if (headerEnd < 0 && buf.Length > MaxBody) return new Request(null, new(), Array.Empty<byte>(), "413 Payload Too Large");
        }
        var all = buf.ToArray();
        var lines = Encoding.ASCII.GetString(all, 0, headerEnd).Split("\r\n");
        var headers = lines.Skip(1).ToList();
        var lengths = HeaderValues("content-length", headers);
        int length = 0;
        if (lengths.Count > 1 || (lengths.Count == 1 && (!int.TryParse(lengths[0], out length) || length < 0)))
            return new Request(lines[0], headers, Array.Empty<byte>(), "400 Bad Request");
        if (length > MaxBody) return new Request(lines[0], headers, Array.Empty<byte>(), "413 Payload Too Large");
        var body = new MemoryStream();
        body.Write(all, headerEnd + 4, all.Length - headerEnd - 4);
        while (body.Length < length)
        {
            var n = s.Read(one, 0, one.Length);
            if (n <= 0) break;
            body.Write(one, 0, n);
        }
        if (body.Length < length) return new Request(lines[0], headers, Array.Empty<byte>(), "400 Bad Request");
        return new Request(lines[0], headers, body.ToArray()[..length], null);
    }

    /// 헤더 값들 (이름은 대소문자 무시). 값이 비어 있어도 "" 를 돌려준다.
    internal static List<string> HeaderValues(string name, List<string> headers) =>
        headers.Select(h => { var i = h.IndexOf(':'); return i < 0 ? (null, "") : (h[..i].Trim().ToLowerInvariant(), h[(i + 1)..].Trim()); })
               .Where(p => p.Item1 == name).Select(p => p.Item2).ToList();

    static int IndexOf(byte[] data, int len, ReadOnlySpan<byte> pat) => data.AsSpan(0, len).IndexOf(pat);

    internal (string Status, string Type, byte[] Body) Handle(Request r)
    {
        static byte[] B(string s) => Encoding.UTF8.GetBytes(s);
        if (r.Error != null) return (r.Error, "text/plain", Array.Empty<byte>());
        var line = r.Line ?? "";
        // 다른 웹사이트가 이 서버를 부르지 못하게: Host 가 정확히 우리 주소, Origin 이 있으면 우리 주소만
        var host = HeaderValues("host", r.Headers).FirstOrDefault();
        var origin = HeaderValues("origin", r.Headers).FirstOrDefault();
        if (host != $"127.0.0.1:{port}" || (origin != null && origin != $"http://127.0.0.1:{port}"))
            return ("403 Forbidden", "text/plain", Array.Empty<byte>());

        if (line.StartsWith("GET /blocked"))
            return ("200 OK", "text/html", B((string)onUi(() => BlockedPage.Html(closeShortcut))!));
        if (line.StartsWith("GET /status"))
            return ("200 OK", "application/json", B((string)onUi(StatusJson)!));
        if (line.StartsWith("POST /later"))
        {
            string text = "";
            try { text = JsonDocument.Parse(r.Body).RootElement.GetProperty("text").GetString() ?? ""; } catch { }
            if (string.IsNullOrWhiteSpace(text)) return ("400 Bad Request", "application/json", B("{}"));
            var ok = (bool)onUi(() => store.AddLater(text))!;
            if (!ok) // 저장이 막혀 있으면 받았다고 하지 않는다
                return ("503 Service Unavailable", "application/json",
                        B(JsonSerializer.Serialize(new { error = (string)onUi(() => store.SaveError ?? I18n.L("기록을 저장할 수 없는 상태예요.", "Saving is unavailable right now."))! })));
            return ("200 OK", "application/json", B((string)onUi(StatusJson)!));
        }
        return ("404 Not Found", "application/json", B("{}"));
    }

    object? StatusJson() => JsonSerializer.Serialize(new
    {
        phase = store.Phase switch { Phase.Focus => "focus", Phase.Wrap => "wrap", Phase.Rest => "break", _ => "idle" },
        block = store.IsBlocking,
        paused = store.IsPaused,
        remainingSec = store.Phase == Phase.Idle ? 0 : (int)Math.Round(store.Remaining),
        task = store.Timer.Task,
    });

    public void Dispose()
    {
        running = false;
        try { listener?.Stop(); } catch { }
    }
}
