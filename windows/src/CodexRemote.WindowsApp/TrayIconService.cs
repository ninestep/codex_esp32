using System.Runtime.InteropServices;
using System.IO;

namespace CodexRemote.WindowsApp;

public sealed class TrayIconService : IDisposable
{
    private const uint CallbackMessage = 0x8001;
    private const uint LeftDoubleClick = 0x0203;
    private const uint RightButtonUp = 0x0205;
    private const uint WmClose = 0x0010;
    private const uint WmDestroy = 0x0002;
    private readonly Action showSettings;
    private readonly Action exit;
    private readonly Thread thread;
    private readonly Native.WindowProcedure procedure;
    private nint window;
    private nint icon;

    public TrayIconService(Action showSettings, Action exit)
    {
        this.showSettings = showSettings; this.exit = exit; procedure = WindowProcedure;
        thread = new(ThreadMain) { IsBackground = true, Name = "Codex Remote tray" }; thread.SetApartmentState(ApartmentState.STA); thread.Start();
    }

    public void Dispose() { if (window != 0) Native.PostMessage(window, WmClose, 0, 0); if (Thread.CurrentThread != thread) thread.Join(TimeSpan.FromSeconds(2)); }

    private void ThreadMain()
    {
        string className = "CodexRemoteTray_" + Guid.NewGuid().ToString("N");
        var windowClass = new Native.WindowClass { Procedure = procedure, Instance = Native.GetModuleHandle(null), ClassName = className };
        Native.RegisterClass(ref windowClass); window = Native.CreateWindowEx(0, className, "Codex Remote", 0, 0, 0, 0, 0, 0, 0, windowClass.Instance, 0);
        string iconPath = Path.Combine(AppContext.BaseDirectory, "Assets", "CodexRemote.ico");
        icon = Native.LoadImage(0, iconPath, 1, 0, 0, 0x0010 | 0x0040);
        var data = CreateData(Native.NotifyAdd); Native.ShellNotifyIcon(Native.NotifyAdd, ref data);
        while (Native.GetMessage(out Native.Message message, 0, 0, 0) > 0) { Native.TranslateMessage(ref message); Native.DispatchMessage(ref message); }
        data = CreateData(Native.NotifyDelete); Native.ShellNotifyIcon(Native.NotifyDelete, ref data);
        if (icon != 0) { Native.DestroyIcon(icon); icon = 0; }
        window = 0;
    }

    private nint WindowProcedure(nint handle, uint message, nuint wParam, nint lParam)
    {
        if (message == CallbackMessage) {
            uint mouse = unchecked((uint)lParam.ToInt64());
            if (mouse == LeftDoubleClick) showSettings();
            if (mouse == RightButtonUp) ShowMenu(handle);
            return 0;
        }
        if (message == WmClose) { Native.DestroyWindow(handle); return 0; }
        if (message == WmDestroy) { Native.PostQuitMessage(0); return 0; }
        return Native.DefWindowProc(handle, message, wParam, lParam);
    }

    private void ShowMenu(nint handle)
    {
        nint menu = Native.CreatePopupMenu();
        try {
            Native.AppendMenu(menu, 0, 1, "设置"); Native.AppendMenu(menu, 0, 2, "退出");
            Native.GetCursorPos(out Native.Point point); Native.SetForegroundWindow(handle);
            uint selected = Native.TrackPopupMenu(menu, 0x0100 | 0x0002, point.X, point.Y, 0, handle, 0);
            if (selected == 1) showSettings(); else if (selected == 2) exit();
        } finally { Native.DestroyMenu(menu); }
    }

    private Native.NotifyIconData CreateData(uint operation) => new() { Size = (uint)Marshal.SizeOf<Native.NotifyIconData>(), Window = window, Id = 1, Flags = 0x1 | 0x2 | 0x4, CallbackMessage = CallbackMessage, Icon = icon, Tip = "Codex Remote" };

    private static class Native
    {
        internal const uint NotifyAdd = 0, NotifyDelete = 2;
        internal delegate nint WindowProcedure(nint window, uint message, nuint wParam, nint lParam);
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct WindowClass { internal uint Style; internal WindowProcedure Procedure; internal int ClassExtra; internal int WindowExtra; internal nint Instance; internal nint Icon; internal nint Cursor; internal nint Background; internal string? MenuName; internal string ClassName; }
        [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct NotifyIconData { internal uint Size; internal nint Window; internal uint Id; internal uint Flags; internal uint CallbackMessage; internal nint Icon; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] internal string Tip; internal uint State; internal uint StateMask; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] internal string Info; internal uint TimeoutOrVersion; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] internal string InfoTitle; internal uint InfoFlags; internal Guid Guid; internal nint BalloonIcon; }
        [StructLayout(LayoutKind.Sequential)] internal struct Point { internal int X; internal int Y; }
        [StructLayout(LayoutKind.Sequential)] internal struct Message { internal nint Window; internal uint Value; internal nuint WParam; internal nint LParam; internal uint Time; internal Point Point; internal uint Private; }
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern ushort RegisterClass(ref WindowClass value);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern nint CreateWindowEx(uint extendedStyle, string className, string windowName, uint style, int x, int y, int width, int height, nint parent, nint menu, nint instance, nint parameter);
        [DllImport("user32.dll")] internal static extern nint DefWindowProc(nint window, uint message, nuint wParam, nint lParam);
        [DllImport("user32.dll")] internal static extern bool DestroyWindow(nint window);
        [DllImport("user32.dll")] internal static extern bool PostMessage(nint window, uint message, nuint wParam, nint lParam);
        [DllImport("user32.dll")] internal static extern sbyte GetMessage(out Message message, nint window, uint minimum, uint maximum);
        [DllImport("user32.dll")] internal static extern bool TranslateMessage(ref Message message);
        [DllImport("user32.dll")] internal static extern nint DispatchMessage(ref Message message);
        [DllImport("user32.dll")] internal static extern void PostQuitMessage(int code);
        [DllImport("user32.dll")] internal static extern nint LoadIcon(nint instance, nint resource);
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern nint LoadImage(nint instance, string name, uint type, int width, int height, uint flags);
        [DllImport("user32.dll")] internal static extern bool DestroyIcon(nint icon);
        [DllImport("shell32.dll", EntryPoint = "Shell_NotifyIconW", CharSet = CharSet.Unicode)] internal static extern bool ShellNotifyIcon(uint operation, ref NotifyIconData data);
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] internal static extern nint GetModuleHandle(string? module);
        [DllImport("user32.dll")] internal static extern nint CreatePopupMenu();
        [DllImport("user32.dll", CharSet = CharSet.Unicode)] internal static extern bool AppendMenu(nint menu, uint flags, nuint identifier, string text);
        [DllImport("user32.dll")] internal static extern uint TrackPopupMenu(nint menu, uint flags, int x, int y, int reserved, nint window, nint rectangle);
        [DllImport("user32.dll")] internal static extern bool DestroyMenu(nint menu);
        [DllImport("user32.dll")] internal static extern bool GetCursorPos(out Point point);
        [DllImport("user32.dll")] internal static extern bool SetForegroundWindow(nint window);
    }
}
