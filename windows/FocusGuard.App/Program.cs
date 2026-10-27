using FocusGuard.Core;

namespace FocusGuard.App;

static class Program
{
    static string CrashLog => Path.Combine(Path.GetDirectoryName(JsonPrefs.DefaultPath)!, "crash.log");

    [STAThread]
    static int Main(string[] args)
    {
        Application.SetHighDpiMode(HighDpiMode.PerMonitorV2);
        Application.EnableVisualStyles();
        Application.SetCompatibleTextRenderingDefault(false);

        if (args.Length > 0 && args[0] == "--selftest") return SelfTest.Run(args.Skip(1).ToArray());

        // 하나만 실행 (두 번 켜면 포트 · 단축키가 겹친다)
        using var single = new Mutex(true, @"Local\FocusGuard.Single", out var first);
        if (!first) return 0;

        Updater.CleanupOld();
        Application.ThreadException += (_, e) => Log(e.Exception);
        AppDomain.CurrentDomain.UnhandledException += (_, e) => Log(e.ExceptionObject as Exception);

        var prefs = new JsonPrefs(JsonPrefs.DefaultPath);
        var store = new Store(prefs);
        Application.Run(new Controller(store, prefs));
        return 0;
    }

    /// 문제가 생기면 %LOCALAPPDATA%\FocusGuard\crash.log 에 남긴다 (제보할 때 이 파일을 보내면 된다)
    static void Log(Exception? e)
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CrashLog)!);
            File.AppendAllText(CrashLog, $"[{DateTime.Now:o}] v{Updater.Current}\n{e}\n\n");
        }
        catch { }
    }
}
