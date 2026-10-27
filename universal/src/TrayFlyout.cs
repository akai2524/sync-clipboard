using System;
using System.Diagnostics;
using System.IO;
using System.Runtime.InteropServices;
using Microsoft.Win32;

// Native, on-demand UI. No browser, Forms, drawing framework or idle animation.
internal sealed class FlyoutState
{
    internal bool Ready, Startup, Preview;
    internal string Phase, PhoneName;
    internal int Changes;
    internal DateTime LastChange;
    internal double Memory;
}

internal static class TrayFlyout
{
    static IntPtr hwnd, owner, icon, smallIcon;
    static Native.WndProc proc = WndProc;
    static Func<FlyoutState> read;
    static Action toggleStartup;
    static Action<bool> exit;
    static readonly IntPtr[] buttons = new IntPtr[4];
    static readonly IntPtr[] fonts = new IntPtr[3];
    static double scale = 1;
    static bool visible, dark, preview, forceDark, opening, reduceMotion;
    static long animationStart, toggleStart;
    static double switchFrom;
    static int targetX, targetY, hover = -1;
    static FlyoutState state;
    const int Width = 376, Height = 430;
    static uint Bg { get { return Color(dark ? 0x151C27 : 0xF5F7FB); } }
    static uint Surface { get { return Color(dark ? 0x1E2939 : 0xFFFFFF); } }
    static uint Border { get { return Color(dark ? 0x2C3A4F : 0xE1E7F0); } }
    static uint Ink { get { return Color(dark ? 0xEAF0F9 : 0x182C49); } }
    static uint Muted { get { return Color(dark ? 0xA0AFC4 : 0x697A91); } }
    static uint Blue { get { return Color(dark ? 0x79B4FF : 0x126FE3); } }
    static uint Tint { get { return Color(dark ? 0x243B59 : 0xEAF3FF); } }
    static uint Color(int rgb) { return (uint)(((rgb & 255) << 16) | (rgb & 0xFF00) | ((rgb >> 16) & 255)); }
    static int S(double value) { return (int)Math.Round(value * scale); }
    static long Milliseconds { get { return Stopwatch.GetTimestamp() / (Stopwatch.Frequency / 1000); } }

    internal static IntPtr SmallIcon
    {
        get {
            if (smallIcon == IntPtr.Zero) smallIcon = UI.LoadImage(IntPtr.Zero, Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lightclip.ico"), 1, 20, 20, 0x10);
            return smallIcon != IntPtr.Zero ? smallIcon : Native.LoadIcon(IntPtr.Zero, new IntPtr(32512));
        }
    }
    internal static void Initialize(IntPtr parent, Func<FlyoutState> reader, Action toggle, Action<bool> quitter, bool isPreview, bool useDark)
    {
        owner = parent; read = reader; toggleStartup = toggle; exit = quitter; preview = isPreview; forceDark = useDark;
    }
    internal static bool Dialog(ref Native.MSG message)
    {
        if (!visible) return false;
        if ((message.message == 0x100 && message.wParam.ToUInt64() == 27) || (message.message == 0x104 && message.wParam.ToUInt64() == 0x73)) { Hide(); return true; }
        return UI.IsDialogMessage(hwnd, ref message);
    }
    internal static void Toggle() { if (visible) Hide(); else Show(); }
    internal static void Changed() { if (visible) { state = read(); UI.InvalidateRect(hwnd, IntPtr.Zero, false); } }
    static void Theme()
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize"))
            dark = forceDark || (k != null && Convert.ToInt32(k.GetValue("AppsUseLightTheme", 1)) == 0);
        int value = dark ? 1 : 0; UI.DwmSetWindowAttribute(hwnd, 20, ref value, 4);
        value = 2; UI.DwmSetWindowAttribute(hwnd, 33, ref value, 4);
        value = (int)Border; UI.DwmSetWindowAttribute(hwnd, 34, ref value, 4);
    }
    static void Create()
    {
        if (hwnd != IntPtr.Zero) return;
        Native.WNDCLASS cls = new Native.WNDCLASS(); cls.style = 8; cls.lpfnWndProc = proc;
        cls.hInstance = Native.GetModuleHandle(null); cls.lpszClassName = "SyncClipboardLite.Flyout";
        cls.hCursor = UI.LoadCursor(IntPtr.Zero, new IntPtr(32512)); cls.hIcon = SmallIcon;
        if (Native.RegisterClass(ref cls) == 0) throw new System.ComponentModel.Win32Exception();
        hwnd = Native.CreateWindowEx(0x00080000 | 0x00010000 | (preview ? 0x40000u : 0x80u), cls.lpszClassName, "轻剪通用版 · 快捷面板", 0x80000000 | 0x02000000,
            0, 0, Width, Height, owner, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (hwnd == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
        icon = UI.LoadImage(IntPtr.Zero, Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "lightclip.ico"), 1, 64, 64, 0x10);
        string[] labels = { "关闭面板", "随 Windows 登录启动", "登录小米账号", "退出轻剪" };
        for (int i = 0; i < buttons.Length; i++)
            buttons[i] = Native.CreateWindowEx(0, "BUTTON", labels[i], 0x5001000B, 0, 0, 1, 1, hwnd, new IntPtr(200 + i), cls.hInstance, IntPtr.Zero);
    }
    static void Layout()
    {
        for (int i = 0; i < fonts.Length; i++) {
            if (fonts[i] != IntPtr.Zero) UI.DeleteObject(fonts[i]);
            int size = i == 0 ? 23 : i == 1 ? 13 : 11;
            fonts[i] = UI.CreateFont(-S(size), 0, 0, 0, i == 0 ? 600 : 400, 0, 0, 0, 1, 0, 0, 5, 0, "Microsoft YaHei UI");
        }
        Move(0, 320, 19, 32, 32); Move(1, 24, 314, 328, 56);
        Move(2, 24, 383, 142, 28); Move(3, 278, 383, 74, 28);
    }
    static void Move(int index, int x, int y, int w, int h) { UI.SetWindowPos(buttons[index], IntPtr.Zero, S(x), S(y), S(w), S(h), 0x14); }
    internal static void Show()
    {
        state = read(); Create();
        UI.Rect anchor; UI.IconId id = new UI.IconId(); id.cbSize = (uint)Marshal.SizeOf(typeof(UI.IconId)); id.hWnd = owner; id.uID = 1;
        Native.POINT cursor; Native.GetCursorPos(out cursor);
        if (UI.Shell_NotifyIconGetRect(ref id, out anchor) != 0 || preview) anchor = new UI.Rect(cursor.x, cursor.y, cursor.x, cursor.y);
        UI.MonitorInfo info = new UI.MonitorInfo(); info.cbSize = Marshal.SizeOf(typeof(UI.MonitorInfo));
        IntPtr monitor = UI.MonitorFromRect(ref anchor, 2); UI.GetMonitorInfo(monitor, ref info);
        uint dx, dy; scale = UI.GetDpiForMonitor(monitor, 0, out dx, out dy) == 0 ? dx / 96.0 : 1;
        Layout(); Theme();
        targetX = Math.Max(info.work.left + S(12), Math.Min(anchor.right - S(Width), info.work.right - S(12 + Width)));
        targetY = Math.Max(info.work.top + S(12), Math.Min(anchor.top - S(Height + 12), info.work.bottom - S(Height + 12)));
        bool enabled; reduceMotion = !UI.SystemParametersInfo(0x1042, 0, out enabled, 0) || !enabled;
        opening = !reduceMotion; animationStart = Stopwatch.GetTimestamp(); visible = true;
        UI.SetLayeredWindowAttributes(hwnd, 0, opening ? (byte)16 : (byte)255, 2);
        UI.SetWindowPos(hwnd, new IntPtr(-1), targetX, targetY + (opening ? S(10) : 0), S(Width), S(Height), 0x40);
        UI.ShowWindow(hwnd, 5); UI.ShowWindow(hwnd, 5); Native.SetForegroundWindow(hwnd); UI.SetFocus(buttons[1]);
        UI.InvalidateRect(hwnd, IntPtr.Zero, false);
        Native.SetTimer(hwnd, new UIntPtr(12), 2000, IntPtr.Zero);
        if (opening) Native.SetTimer(hwnd, new UIntPtr(11), 15, IntPtr.Zero);
    }
    internal static void Hide()
    {
        visible = false; opening = false;
        Native.KillTimer(hwnd, new UIntPtr(11)); Native.KillTimer(hwnd, new UIntPtr(12)); Native.KillTimer(hwnd, new UIntPtr(14));
        UI.ShowWindow(hwnd, 0); hover = -1;
        if (preview) Native.PostQuitMessage(0);
    }
    static IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        try {
            if (msg == 0x14) return new IntPtr(1);
            if (msg == 0xF) { Paint(h); return IntPtr.Zero; }
            if (msg == 0x2B) { DrawButton(l); return new IntPtr(1); }
            if (msg == 0x1A) { Theme(); Changed(); return IntPtr.Zero; }
            if (!preview && (msg == 0x1C && w == IntPtr.Zero || msg == 6 && (w.ToInt64() & 0xFFFF) == 0) && visible) { Hide(); return IntPtr.Zero; }
            if (msg == 0x10) { Hide(); return IntPtr.Zero; }
            if (msg == 0x113) {
                if (w.ToInt32() == 11) {
                    double t = Math.Min(1, (Stopwatch.GetTimestamp() - animationStart) / (Stopwatch.Frequency * .18));
                    double ease = 1 - Math.Pow(1 - t, 3);
                    UI.SetLayeredWindowAttributes(h, 0, (byte)(16 + 239 * ease), 2);
                    UI.SetWindowPos(h, IntPtr.Zero, targetX, targetY + S(10 * (1 - ease)), 0, 0, 0x15);
                    if (t >= 1) { opening = false; Native.KillTimer(h, new UIntPtr(11)); }
                } else if (w.ToInt32() == 12) Changed();
                else if (w.ToInt32() == 14) {
                    UI.InvalidateRect(buttons[1], IntPtr.Zero, false);
                    if (Milliseconds - toggleStart >= 120) { toggleStart = 0; Native.KillTimer(h, new UIntPtr(14)); }
                }
                return IntPtr.Zero;
            }
            if (msg == 0x20 || msg == 0x200) {
                int next = msg == 0x20 ? Array.IndexOf(buttons, w) : -1;
                if (hover != next) { int old = hover; hover = next; if (old >= 0) UI.InvalidateRect(buttons[old], IntPtr.Zero, false); if (next >= 0) UI.InvalidateRect(buttons[next], IntPtr.Zero, false); }
            }
            if (msg == 0x111) {
                if (((w.ToInt64() >> 16) & 0xFFFF) != 0) return IntPtr.Zero;
                int command = w.ToInt32() & 0xFFFF;
                if (command == 2 || command == 200) Hide();
                else if (command == 201) {
                    switchFrom = state.Startup ? 1 : 0; toggleStartup(); state = read();
                    if (!reduceMotion) { toggleStart = Milliseconds; Native.SetTimer(h, new UIntPtr(14), 15, IntPtr.Zero); }
                    UI.SetWindowText(buttons[1], state.Startup ? "关闭登录自启动" : "开启登录自启动"); Changed();
                }
                else if (command == 202 || command == 203) { Hide(); exit(command == 202); }
                return IntPtr.Zero;
            }
        } catch (Exception error) {
            try { File.WriteAllText(AppStorage.UiErrorFile, error.ToString()); } catch { }
            Hide();
        }
        return Native.DefWindowProc(h, msg, w, l);
    }

    static void Paint(IntPtr h)
    {
        UI.PaintStruct ps; IntPtr dc = UI.BeginPaint(h, out ps);
        if (dc == IntPtr.Zero) return;
        IntPtr buffer = UI.CreateCompatibleDC(dc), bitmap = UI.CreateCompatibleBitmap(dc, S(Width), S(Height));
        IntPtr previous = UI.SelectObject(buffer, bitmap);
        try {
            Box(buffer, 0, 0, Width, Height, 0, Bg, Bg);
            if (icon != IntPtr.Zero) UI.DrawIconEx(buffer, S(24), S(24), icon, S(42), S(42), 0, IntPtr.Zero, 3);
            Text(buffer, "轻剪", 78, 19, 220, 33, 0, Ink, false);
            Text(buffer, "文字与图片 · 双向复制", 79, 53, 225, 20, 2, Muted, false);
            Box(buffer, 24, 94, 328, 170, 16, Surface, Border);
            // A static device diagram; it deliberately does not imply device presence.
            Box(buffer, 52, 119, 87, 55, 6, Tint, Blue);
            Line(buffer, 95, 175, 95, 183, Blue, 2); Line(buffer, 79, 184, 112, 184, Blue, 2);
            Box(buffer, 253, 110, 40, 77, 8, Tint, Blue); Line(buffer, 266, 118, 280, 118, Blue, 2);
            Line(buffer, 267, 179, 279, 179, Blue, 2);
            Line(buffer, 160, 138, 225, 138, Blue, 2); Line(buffer, 218, 132, 225, 138, Blue, 2); Line(buffer, 218, 144, 225, 138, Blue, 2);
            Line(buffer, 225, 157, 160, 157, Blue, 2); Line(buffer, 167, 151, 160, 157, Blue, 2); Line(buffer, 167, 163, 160, 157, Blue, 2);
            Text(buffer, "这台电脑", 47, 192, 96, 21, 2, Muted, true);
            Text(buffer, state.PhoneName ?? "小米手机", 206, 192, 134, 21, 2, Muted, true);
            Box(buffer, 110, 225, 156, 25, 12, Tint, Tint);
            Text(buffer, preview ? "界面预览" : state.Ready ? "服务已启动 · 待验证" : "正在启动", 110, 225, 156, 25, 2, Blue, true);
            Text(buffer, "本进程 " + state.Memory.ToString("F1") + " MB", 26, 277, 200, 22, 1, Ink, false);
            Text(buffer, "不含小米后台服务", 214, 278, 137, 21, 2, Muted, false);
            Line(buffer, 24, 378, 352, 378, Border, 1);
            UI.BitBlt(dc, 0, 0, S(Width), S(Height), buffer, 0, 0, 0xCC0020);
        } finally { UI.SelectObject(buffer, previous); UI.DeleteObject(bitmap); UI.DeleteDC(buffer); UI.EndPaint(h, ref ps); }
    }
    static void DrawButton(IntPtr pointer)
    {
        UI.DrawItem item = (UI.DrawItem)Marshal.PtrToStructure(pointer, typeof(UI.DrawItem));
        int i = (int)item.id - 200; if (i < 0 || i >= buttons.Length) return;
        IntPtr dc = item.dc; bool down = (item.state & 1) != 0, focused = (item.state & 0x10) != 0;
        int width = (int)Math.Round((item.rect.right - item.rect.left) / scale), height = (int)Math.Round((item.rect.bottom - item.rect.top) / scale);
        Box(dc, 0, 0, width, height, 0, Bg, Bg);
        if (i == 0) {
            if (hover == i || down) Box(dc, 0, 0, width, height, 9, Tint, Tint);
            Line(dc, 12, 12, 20, 20, Muted, 1); Line(dc, 12, 20, 20, 12, Muted, 1);
        } else if (i == 1) {
            Box(dc, 0, 0, width, height, 12, down || hover == i ? Tint : Surface, Border);
            Text(dc, "登录自启动", 14, 8, 205, 21, 1, Ink, false);
            Text(dc, "登录后自动在后台运行", 14, 30, 240, 18, 2, Muted, false);
            Box(dc, 274, 18, 38, 21, 11, state.Startup ? Blue : Border, state.Startup ? Blue : Border);
            double position = state.Startup ? 1 : 0;
            if (toggleStart > 0) { double t = Math.Min(1, (Milliseconds - toggleStart) / 120.0); position = switchFrom + (position - switchFrom) * (1 - Math.Pow(1 - t, 3)); }
            Box(dc, 277 + 16 * position, 21, 15, 15, 8, Color(0xFFFFFF), Color(0xFFFFFF));
        } else {
            if (hover == i || down) Box(dc, 0, 0, width, height, 6, Tint, Tint);
            Text(dc, i == 2 ? "登录小米账号" : "退出轻剪", 0, 0, width, height, 2, Muted, true);
        }
        if (focused && (item.state & 0x200) == 0) { UI.Rect focus = new UI.Rect(S(4), S(4), S(width - 4), S(height - 4)); UI.DrawFocusRect(dc, ref focus); }
    }
    static void Box(IntPtr dc, double x, double y, double w, double h, double r, uint fill, uint stroke)
    {
        IntPtr brush = UI.CreateSolidBrush(fill), pen = UI.CreatePen(0, S(1), stroke);
        IntPtr a = UI.SelectObject(dc, brush), b = UI.SelectObject(dc, pen);
        UI.RoundRect(dc, S(x), S(y), S(x + w), S(y + h), S(r * 2), S(r * 2));
        UI.SelectObject(dc, a); UI.SelectObject(dc, b); UI.DeleteObject(brush); UI.DeleteObject(pen);
    }
    static void Line(IntPtr dc, double x1, double y1, double x2, double y2, uint color, int width)
    {
        IntPtr pen = UI.CreatePen(0, Math.Max(1, S(width)), color), old = UI.SelectObject(dc, pen);
        UI.MoveToEx(dc, S(x1), S(y1), IntPtr.Zero); UI.LineTo(dc, S(x2), S(y2)); UI.SelectObject(dc, old); UI.DeleteObject(pen);
    }
    static void Text(IntPtr dc, string text, double x, double y, double w, double h, int font, uint color, bool center)
    {
        UI.SetBkMode(dc, 1); UI.SetTextColor(dc, color); IntPtr old = UI.SelectObject(dc, fonts[font]);
        UI.Rect rect = new UI.Rect(S(x), S(y), S(x + w), S(y + h));
        UI.DrawText(dc, text, -1, ref rect, 0x20 | 0x4 | 0x800 | 0x8000 | (center ? 1u : 0u)); UI.SelectObject(dc, old);
    }
    internal static void Dispose()
    {
        if (hwnd != IntPtr.Zero) { Native.DestroyWindow(hwnd); hwnd = IntPtr.Zero; }
        foreach (IntPtr font in fonts) if (font != IntPtr.Zero) UI.DeleteObject(font);
        if (icon != IntPtr.Zero) UI.DestroyIcon(icon);
        if (smallIcon != IntPtr.Zero) UI.DestroyIcon(smallIcon);
    }
    internal static int Preview(bool useDark)
    {
        UI.SetProcessDpiAwarenessContext(new IntPtr(-4));
        bool startup = true;
        Initialize(IntPtr.Zero, () => { using (Process p = Process.GetCurrentProcess()) return new FlyoutState { Preview = true, Ready = false, Startup = startup, Memory = p.WorkingSet64 / 1048576.0 }; },
            () => startup = !startup, restore => Native.PostQuitMessage(0), true, useDark);
        Show(); Native.MSG msg;
        while (Native.GetMessage(out msg, IntPtr.Zero, 0, 0) > 0) { if (!Dialog(ref msg)) { Native.TranslateMessage(ref msg); Native.DispatchMessage(ref msg); } }
        Dispose(); return 0;
    }
}

internal static class UI
{
    [StructLayout(LayoutKind.Sequential)] internal struct Rect { public int left, top, right, bottom; public Rect(int a, int b, int c, int d) { left=a; top=b; right=c; bottom=d; } }
    [StructLayout(LayoutKind.Sequential)] internal struct MonitorInfo { public int cbSize; public Rect monitor, work; public uint flags; }
    [StructLayout(LayoutKind.Sequential)] internal struct IconId { public uint cbSize; public IntPtr hWnd; public uint uID; public Guid guid; }
    [StructLayout(LayoutKind.Sequential)] internal struct PaintStruct { public IntPtr dc; public int erase; public Rect rect; public int restore, update; [MarshalAs(UnmanagedType.ByValArray, SizeConst=32)] public byte[] reserved; }
    [StructLayout(LayoutKind.Sequential)] internal struct DrawItem { public uint type, id, itemId, action, state; public IntPtr hwnd, dc; public Rect rect; public UIntPtr data; }
    [DllImport("user32")] internal static extern bool SetProcessDpiAwarenessContext(IntPtr context);
    [DllImport("user32")] internal static extern IntPtr LoadCursor(IntPtr h, IntPtr n);
    [DllImport("user32", CharSet=CharSet.Unicode)] internal static extern IntPtr LoadImage(IntPtr h, string file, uint type, int x, int y, uint flags);
    [DllImport("user32")] internal static extern bool DestroyIcon(IntPtr h);
    [DllImport("user32")] internal static extern bool DrawIconEx(IntPtr dc, int x,int y,IntPtr icon,int w,int h,uint step,IntPtr brush,uint flags);
    [DllImport("user32")] internal static extern bool IsDialogMessage(IntPtr h, ref Native.MSG msg);
    [DllImport("user32")] internal static extern bool SetWindowPos(IntPtr h,IntPtr after,int x,int y,int w,int height,uint flags);
    [DllImport("user32")] internal static extern bool ShowWindow(IntPtr h,int cmd);
    [DllImport("user32")] internal static extern bool InvalidateRect(IntPtr h,IntPtr rect,bool erase);
    [DllImport("user32")] internal static extern IntPtr SetFocus(IntPtr h);
    [DllImport("user32", CharSet=CharSet.Unicode)] internal static extern bool SetWindowText(IntPtr h,string text);
    [DllImport("user32")] internal static extern bool SetLayeredWindowAttributes(IntPtr h,uint key,byte alpha,uint flags);
    [DllImport("user32")] internal static extern bool GetWindowRect(IntPtr h,out Rect rect);
    [DllImport("user32")] internal static extern bool ScreenToClient(IntPtr h,ref Native.POINT point);
    [DllImport("user32")] internal static extern bool SystemParametersInfo(uint action,uint param,out bool value,uint flags);
    [DllImport("user32")] internal static extern IntPtr MonitorFromRect(ref Rect rect,uint flags);
    [DllImport("user32", CharSet=CharSet.Unicode)] internal static extern bool GetMonitorInfo(IntPtr h,ref MonitorInfo info);
    [DllImport("shcore")] internal static extern int GetDpiForMonitor(IntPtr monitor,int type,out uint x,out uint y);
    [DllImport("shell32")] internal static extern int Shell_NotifyIconGetRect(ref IconId id,out Rect rect);
    [DllImport("dwmapi")] internal static extern int DwmSetWindowAttribute(IntPtr h,int attribute,ref int value,int size);
    [DllImport("user32")] internal static extern IntPtr BeginPaint(IntPtr h,out PaintStruct ps);
    [DllImport("user32")] internal static extern bool EndPaint(IntPtr h,ref PaintStruct ps);
    [DllImport("user32")] internal static extern bool DrawFocusRect(IntPtr dc,ref Rect r);
    [DllImport("user32", CharSet=CharSet.Unicode)] internal static extern int DrawText(IntPtr dc,string text,int length,ref Rect r,uint flags);
    [DllImport("gdi32")] internal static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32")] internal static extern IntPtr CreateCompatibleBitmap(IntPtr dc,int w,int h);
    [DllImport("gdi32")] internal static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32")] internal static extern IntPtr SelectObject(IntPtr dc,IntPtr obj);
    [DllImport("gdi32")] internal static extern bool DeleteObject(IntPtr obj);
    [DllImport("gdi32")] internal static extern IntPtr CreateSolidBrush(uint color);
    [DllImport("gdi32")] internal static extern IntPtr CreatePen(int style,int width,uint color);
    [DllImport("gdi32")] internal static extern bool RoundRect(IntPtr dc,int x,int y,int r,int b,int w,int h);
    [DllImport("gdi32")] internal static extern bool MoveToEx(IntPtr dc,int x,int y,IntPtr old);
    [DllImport("gdi32")] internal static extern bool LineTo(IntPtr dc,int x,int y);
    [DllImport("gdi32")] internal static extern bool BitBlt(IntPtr dc,int x,int y,int w,int h,IntPtr src,int sx,int sy,uint op);
    [DllImport("gdi32")] internal static extern int SetBkMode(IntPtr dc,int mode);
    [DllImport("gdi32")] internal static extern uint SetTextColor(IntPtr dc,uint color);
    [DllImport("gdi32", CharSet=CharSet.Unicode)] internal static extern IntPtr CreateFont(int height,int width,int escape,int angle,int weight,uint italic,uint underline,uint strike,uint charset,uint output,uint clip,uint quality,uint pitch,string name);
}
