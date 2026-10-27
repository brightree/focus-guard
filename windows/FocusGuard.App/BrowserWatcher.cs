using System.Collections.Concurrent;
using System.Diagnostics;
using System.Runtime.InteropServices;
using FlaUI.Core.AutomationElements;
using FlaUI.Core.Definitions;
using FlaUI.Core.Input;
using FlaUI.Core.WindowsAPI;
using FlaUI.UIA3;
using FocusGuard.Core;

namespace FocusGuard.App;

/// 맨 앞 창을 1초마다 확인한다 (별도 스레드, 화면은 멈추지 않는다).
/// - 브라우저면 주소창 글자를 윈도우 접근성 기능(UI Automation)으로 읽는다.
/// - 집중 · 정리 중: 차단 사이트면 주소창에 차단 페이지 주소를 넣고 Enter.
/// - 그 외: 딴짓 시간 · 연속 사용 경고, 학습 통계용 앱 이름 · 도메인을 화면 스레드의 Store 에 넘긴다.
/// 윈도우에서는 지금 보는 탭만 읽을 수 있다 (미리 열어둔 탭은 그 탭으로 가는 순간 막힌다).
sealed class BrowserWatcher : IDisposable
{
    static readonly HashSet<string> Browsers = new(StringComparer.OrdinalIgnoreCase)
        { "chrome", "msedge", "brave", "firefox", "vivaldi", "opera", "whale" };

    readonly Controller app;
    readonly int selfPid = Environment.ProcessId;
    readonly Dictionary<int, string> appNames = new();
    readonly Dictionary<string, IntPtr> lastWindowForSite = new();
    readonly ConcurrentQueue<Action> jobs = new();
    Thread? thread;
    volatile bool running;
    UIA3Automation? automation;
    IntPtr cachedHwnd;
    AutomationElement? cachedBar;
    DateTime lastRedirect;

    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr hWnd);

    public BrowserWatcher(Controller app) => this.app = app;

    public void Start()
    {
        running = true;
        thread = new Thread(Loop) { IsBackground = true, Name = "FocusGuard watcher" };
        thread.SetApartmentState(ApartmentState.MTA);
        thread.Start();
    }

    void Loop()
    {
        try { automation = new UIA3Automation(); } catch { automation = null; }
        while (running)
        {
            while (jobs.TryDequeue(out var job)) { try { job(); } catch { } }
            try { TickOnce(); } catch { cachedBar = null; }
            Thread.Sleep(1000);
        }
        automation?.Dispose();
    }

    void TickOnce()
    {
        var active = Win32.IdleSeconds() < 60;
        string? appName = null, url = null;
        var isSelf = false;
        IntPtr hwnd = IntPtr.Zero;
        if (Win32.Foreground() is { } fg)
        {
            using var proc = fg.Proc;
            hwnd = fg.Hwnd;
            isSelf = proc.Id == selfPid;
            if (!isSelf)
            {
                appName = AppName(proc);
                if (Browsers.Contains(proc.ProcessName)) url = ReadAddress(hwnd);
            }
        }
        var snap = app.Snapshot;
        var domain = url != null ? SiteRules.Domain(url) : null;
        var site = SiteRules.Match(domain, snap.Sites, snap.Allow);
        if (site != null) lock (lastWindowForSite) lastWindowForSite[site] = hwnd;
        if (snap.Blocking && site != null && (DateTime.Now - lastRedirect).TotalSeconds > 3 && cachedBar != null)
        {
            lastRedirect = DateTime.Now;
            Redirect(cachedBar, url!, LocalServer.Port);
        }
        app.Post(() =>
        {
            if (!isSelf) app.Store.ReportStudyUsage(appName, domain, active);
            if (site == null) app.Store.ReportBrowsing(null, active);
            else if (!snap.Blocking && app.Store.ReportBrowsing(site, active) is { } w) app.ShowWarning(w.Min, w.Site);
        });
    }

    /// 통계에 보일 앱 이름 ("Google Chrome", "Microsoft Word" …)
    string AppName(Process p)
    {
        if (appNames.TryGetValue(p.Id, out var n)) return n;
        try
        {
            var file = p.MainModule?.FileName;
            n = file != null ? FileVersionInfo.GetVersionInfo(file).FileDescription ?? "" : "";
        }
        catch { n = ""; }
        if (string.IsNullOrWhiteSpace(n)) n = p.ProcessName;
        if (appNames.Count > 500) appNames.Clear();
        return appNames[p.Id] = n.Trim();
    }

    string? ReadAddress(IntPtr hwnd)
    {
        if (automation == null) return null;
        if (hwnd != cachedHwnd || cachedBar == null) { cachedHwnd = hwnd; cachedBar = FindAddressBar(automation, hwnd); }
        var v = ReadValue(cachedBar);
        if (v == null) cachedBar = null;
        return v;
    }

    /// 브라우저 창에서 주소창(첫 번째 입력 칸)을 찾는다. 주소창은 웹 페이지 내용보다 먼저 나오므로 빨리 찾힌다.
    public static AutomationElement? FindAddressBar(UIA3Automation automation, IntPtr hwnd)
    {
        try
        {
            var win = automation.FromHandle(hwnd);
            var cf = automation.ConditionFactory;
            return win.FindFirstDescendant(cf.ByAutomationId("urlbar-input")) // Firefox
                ?? win.FindFirstDescendant(cf.ByControlType(ControlType.Edit));
        }
        catch { return null; }
    }

    public static string? ReadValue(AutomationElement? bar)
    {
        try { return bar?.Patterns.Value.PatternOrDefault?.Value.Value; } catch { return null; }
    }

    /// 주소창에 차단 페이지 주소를 넣고 Enter. 원래 주소는 # 뒤에 (서버로는 보내지지 않는다).
    public static void Redirect(AutomationElement bar, string url, int port)
    {
        var original = url.Contains("://") ? url : "https://" + url;
        var blocked = $"http://127.0.0.1:{port}/blocked#{Uri.EscapeDataString(original)}";
        try
        {
            bar.Focus();
            bar.Patterns.Value.Pattern.SetValue(blocked);
            Keyboard.Type(VirtualKeyShort.ENTER);
        }
        catch { }
    }

    /// 경고 창에서 "이 탭 닫기": 그 사이 다른 사이트로 옮겼다면 엉뚱한 탭을 닫지 않도록 아무것도 하지 않는다
    public void CloseTabIfStillOn(string site) => jobs.Enqueue(() =>
    {
        IntPtr hwnd;
        lock (lastWindowForSite) if (!lastWindowForSite.TryGetValue(site, out hwnd)) return;
        if (automation == null) return;
        var snap = app.Snapshot;
        var now = SiteRules.Match(SiteRules.Domain(ReadValue(FindAddressBar(automation, hwnd)) ?? ""), snap.Sites, snap.Allow);
        if (now != site) return;
        SetForegroundWindow(hwnd);
        Thread.Sleep(200);
        Keyboard.TypeSimultaneously(VirtualKeyShort.CONTROL, VirtualKeyShort.KEY_W);
    });

    public void Dispose() => running = false;
}
