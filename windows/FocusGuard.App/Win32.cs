using System.Diagnostics;
using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace FocusGuard.App;

/// 윈도우 기능 몇 가지 (맨 앞 창, 자리 비움 시간, 전역 단축키, 로그인 시 자동 실행)
static class Win32
{
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint pid);
    [DllImport("user32.dll")] static extern bool GetLastInputInfo(ref LASTINPUTINFO info);
    [DllImport("user32.dll")] public static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
    [DllImport("user32.dll")] public static extern bool UnregisterHotKey(IntPtr hWnd, int id);

    [StructLayout(LayoutKind.Sequential)]
    struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }

    /// 맨 앞 창과 그 프로그램 (없으면 null)
    public static (IntPtr Hwnd, Process Proc)? Foreground()
    {
        var h = GetForegroundWindow();
        if (h == IntPtr.Zero) return null;
        GetWindowThreadProcessId(h, out var pid);
        try { return (h, Process.GetProcessById((int)pid)); } catch { return null; }
    }

    /// 마지막 키보드 · 마우스 입력 뒤 지난 초
    public static double IdleSeconds()
    {
        var info = new LASTINPUTINFO { cbSize = (uint)Marshal.SizeOf<LASTINPUTINFO>() };
        if (!GetLastInputInfo(ref info)) return 0;
        return unchecked((uint)Environment.TickCount - info.dwTime) / 1000.0;
    }

    const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    const string RunName = "FocusGuard";

    public static bool LaunchAtLogin
    {
        get
        {
            using var k = Registry.CurrentUser.OpenSubKey(RunKey);
            return k?.GetValue(RunName) is string;
        }
        set
        {
            using var k = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) k.SetValue(RunName, $"\"{Environment.ProcessPath}\"");
            else k.DeleteValue(RunName, false);
        }
    }
}

/// 전역 단축키 (Ctrl+Alt+L → 나중에 할 것). 윈도우에선 Alt+Shift 가 입력 언어 전환이라 피한다.
sealed class HotKey : NativeWindow, IDisposable
{
    const int WM_HOTKEY = 0x0312, Id = 0xF6;
    const uint MOD_ALT = 0x1, MOD_CONTROL = 0x2, MOD_NOREPEAT = 0x4000;
    public const string Label = "Ctrl+Alt+L";
    readonly Action onPress;

    public HotKey(Action onPress)
    {
        this.onPress = onPress;
        CreateHandle(new CreateParams());
        Win32.RegisterHotKey(Handle, Id, MOD_CONTROL | MOD_ALT | MOD_NOREPEAT, (uint)Keys.L);
    }

    protected override void WndProc(ref Message m)
    {
        if (m.Msg == WM_HOTKEY && m.WParam.ToInt32() == Id) onPress();
        base.WndProc(ref m);
    }

    public void Dispose()
    {
        Win32.UnregisterHotKey(Handle, Id);
        DestroyHandle();
    }
}
