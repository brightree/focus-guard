using System.Diagnostics;
using System.Net.Http;
using FlaUI.UIA3;
using FocusGuard.Core;

namespace FocusGuard.App;

/// FocusGuard.exe --selftest [로그 파일] [--chrome]
/// 실제 기록 · 설정은 건드리지 않고(임시 폴더) 앱을 띄워 모든 창을 열고 닫고, 타이머 흐름 · 로컬 서버 · 접근성 기능을 확인한다.
/// --chrome: 크롬을 열어 주소창 읽기 · 차단 페이지로 바꾸기까지 확인한다 (CI 용).
static class SelfTest
{
    public static int Run(string[] args)
    {
        var logPath = args.FirstOrDefault(a => !a.StartsWith("--")) ?? Path.Combine(Path.GetTempPath(), "focusguard-selftest.log");
        var lines = new List<string>();
        var failures = 0;
        void ok(string name, bool pass, string detail = "") { lines.Add($"{(pass ? "PASS" : "FAIL")} {name} {detail}"); if (!pass) failures++; }
        void step(string name, Action a) { try { a(); ok(name, true); } catch (Exception e) { ok(name, false, e.ToString()); } }

        var dir = Path.Combine(Path.GetTempPath(), "fg-selftest-" + Guid.NewGuid().ToString("N"));
        Controller? ctl = null;
        try
        {
            var prefs = new JsonPrefs(Path.Combine(dir, "prefs.json"));
            var clock = DateTime.Now;
            var store = new Store(prefs, () => clock, Path.Combine(dir, "data"));
            const int port = 47399; // 실제 앱과 겹치지 않게
            ctl = new Controller(store, prefs, selfTest: true, port: port);
            ok("server listening", ctl.ServerListening);
            void pump() { for (var i = 0; i < 5; i++) Application.DoEvents(); }

            foreach (var lang in new[] { Lang.Ko, Lang.En })
            {
                step($"[{lang}] language", () => store.SetLanguage(lang));
                step($"[{lang}] add to-dos", () =>
                {
                    store.AddTodo("pset 3", TodoKind.Must, store.TodayKey);
                    store.AddTodo("read paper", TodoKind.Nice, Fmt.DayKey(clock.AddDays(1)));
                    store.AddLater("rewatch lecture");
                });
                step($"[{lang}] dashboard", () => { ctl.ShowDashboard(); pump(); });
                step($"[{lang}] stats", () => { ctl.ShowStats(); pump(); });
                step($"[{lang}] settings", () => { ctl.ShowSettings(); pump(); });
                step($"[{lang}] plan today", () => { ctl.ShowPlan(store.TodayKey); pump(); });
                step($"[{lang}] plan tomorrow", () => { ctl.ShowPlan(Fmt.DayKey(clock.AddDays(1))); pump(); });
                step($"[{lang}] start window", () => { ctl.ShowStart(); pump(); });
                step($"[{lang}] capture", () => { ctl.ShowCapture(); pump(); });
                step($"[{lang}] warning", () => { ctl.ShowWarning(10, "youtube.com"); pump(); });
                step($"[{lang}] update window", () => { ctl.ShowUpdate(); pump(); });
                step($"[{lang}] panel idle", () => { ctl.TogglePanel(); pump(); ctl.HidePanel(); });
                step($"[{lang}] focus → pause → resume", () =>
                {
                    store.StartFocus("selftest");
                    ctl.TogglePanel(); pump();
                    store.Pause(); pump();
                    store.Resume(); pump();
                    ctl.HidePanel();
                });
                step($"[{lang}] give-up window", () => { ctl.ShowGiveUp(); pump(); });
                step($"[{lang}] focus ends → wrap window", () =>
                {
                    clock = clock.AddMinutes(store.Settings.FocusMin + 1);
                    store.Tick(); pump();
                    if (store.Phase != Phase.Wrap) throw new Exception($"phase {store.Phase}");
                    if (!ctl.OpenWindows.Any(w => w is WrapForm)) throw new Exception("wrap window not shown");
                });
                step($"[{lang}] wrap → break → idle opens start", () =>
                {
                    clock = clock.AddMinutes(store.Settings.WrapMin + 1); store.Tick(); pump();
                    clock = clock.AddMinutes(store.Settings.BreakMin + 1); store.Tick(); pump();
                    if (store.Phase != Phase.Idle) throw new Exception($"phase {store.Phase}");
                    if (!ctl.OpenWindows.Any(w => w is StartForm)) throw new Exception("start window not shown");
                });
                step($"[{lang}] refresh all windows with data", () => { foreach (var w in ctl.OpenWindows.ToList()) w.RefreshView(true); pump(); });
                step($"[{lang}] close all windows", () => { foreach (var w in ctl.OpenWindows.ToList()) w.Close(); pump(); });
            }

            step("blocked page + status over HTTP", () =>
            {
                using var http = new HttpClient();
                var page = http.GetStringAsync($"http://127.0.0.1:{port}/blocked").Result;
                if (!page.Contains("<html")) throw new Exception("no html");
                var status = http.GetStringAsync($"http://127.0.0.1:{port}/status").Result;
                if (!status.Contains("\"block\":")) throw new Exception(status);
            });
            step("save data", () => { if (!store.SaveNow()) throw new Exception(store.SaveError); });
            step("UI Automation available", () => { using var a = new UIA3Automation(); _ = a.GetDesktop().Name; });
            step("hotkey register", () => new HotKey(() => { }).Dispose());

            if (args.Contains("--chrome")) ChromeTest(ok, port);
        }
        catch (Exception e) { ok("selftest crashed", false, e.ToString()); }
        finally
        {
            try { ctl?.Shutdown(); } catch { }
            try { Directory.Delete(dir, true); } catch { }
        }
        lines.Add(failures == 0 ? "ALL PASS" : $"{failures} FAILED");
        File.WriteAllLines(logPath, lines);
        return failures == 0 ? 0 : 1;
    }

    /// 크롬을 열어 주소창을 읽고, 차단 페이지로 바꿔지는지 본다
    static void ChromeTest(Action<string, bool, string> ok, int port)
    {
        var chrome = new[] { @"C:\Program Files\Google\Chrome\Application\chrome.exe", @"C:\Program Files (x86)\Google\Chrome\Application\chrome.exe" }.FirstOrDefault(File.Exists);
        if (chrome == null) { ok("chrome found", false, "not installed"); return; }
        var profile = Path.Combine(Path.GetTempPath(), "fg-chrome-" + Guid.NewGuid().ToString("N"));
        using var p = Process.Start(chrome, $"--user-data-dir=\"{profile}\" --no-first-run --no-default-browser-check --new-window https://example.com/");
        try
        {
            using var automation = new UIA3Automation();
            string? value = null;
            FlaUI.Core.AutomationElements.AutomationElement? bar = null;
            for (var i = 0; i < 30 && value == null; i++)
            {
                Thread.Sleep(1000);
                var win = Process.GetProcessesByName("chrome").Select(x => x.MainWindowHandle).FirstOrDefault(h => h != IntPtr.Zero);
                if (win == IntPtr.Zero) continue;
                bar = BrowserWatcher.FindAddressBar(automation, win);
                value = BrowserWatcher.ReadValue(bar);
                if (value != null && !value.Contains("example.com")) value = null;
            }
            ok("chrome address bar read", value != null, value ?? "");
            ok("chrome domain parsed", SiteRules.Domain(value ?? "") == "example.com", SiteRules.Domain(value ?? "") ?? "");
            if (bar == null) return;
            BrowserWatcher.Redirect(bar, value!, port);
            string? after = null;
            for (var i = 0; i < 10; i++) { Thread.Sleep(1000); after = BrowserWatcher.ReadValue(bar); if (after?.Contains("127.0.0.1") == true) break; }
            ok("chrome redirected to blocked page", after?.Contains($"127.0.0.1:{port}/blocked") == true, after ?? "");
        }
        catch (Exception e) { ok("chrome test", false, e.ToString()); }
        finally
        {
            foreach (var c in Process.GetProcessesByName("chrome")) { try { c.Kill(); } catch { } }
            try { Directory.Delete(profile, true); } catch { }
        }
    }
}
