using System;
using System.Runtime.InteropServices;
internal static class Native
{
    [UnmanagedFunctionPointer(CallingConvention.Winapi)] internal delegate IntPtr WndProc(IntPtr h, uint msg, IntPtr w, IntPtr l);
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct WNDCLASS {
        public uint style; public WndProc lpfnWndProc; public int cbClsExtra, cbWndExtra; public IntPtr hInstance, hIcon, hCursor, hbrBackground;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszMenuName;
        [MarshalAs(UnmanagedType.LPWStr)] public string lpszClassName;
    }
    [StructLayout(LayoutKind.Sequential)] internal struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] internal struct MSG { public IntPtr hwnd; public uint message; public UIntPtr wParam; public IntPtr lParam; public uint time; public POINT pt; public uint lPrivate; }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] internal struct NOTIFYICONDATA {
        public int cbSize; public IntPtr hWnd; public uint uID, uFlags, uCallbackMessage; public IntPtr hIcon;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)] public string szTip;
        public uint dwState, dwStateMask;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 256)] public string szInfo;
        public uint uTimeout;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 64)] public string szInfoTitle;
        public uint dwInfoFlags; public Guid guidItem; public IntPtr hBalloonIcon;
    }
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern ushort RegisterClass(ref WNDCLASS c);
    [DllImport("user32", CharSet = CharSet.Unicode, SetLastError = true)] internal static extern IntPtr CreateWindowEx(uint e, string c, string n, uint s, int x, int y, int w, int h, IntPtr parent, IntPtr menu, IntPtr inst, IntPtr p);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern IntPtr DefWindowProc(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern int GetMessage(out MSG m, IntPtr h, uint min, uint max);
    [DllImport("user32")] internal static extern bool TranslateMessage(ref MSG m);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern IntPtr DispatchMessage(ref MSG m);
    [DllImport("user32")] internal static extern void PostQuitMessage(int code);
    [DllImport("user32")] internal static extern bool PostMessage(IntPtr h, uint m, IntPtr w, IntPtr l);
    [DllImport("user32")] internal static extern bool DestroyWindow(IntPtr h);
    [DllImport("user32")] internal static extern UIntPtr SetTimer(IntPtr h, UIntPtr id, uint ms, IntPtr callback);
    [DllImport("user32")] internal static extern bool KillTimer(IntPtr h, UIntPtr id);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern uint RegisterWindowMessage(string name);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern int MessageBox(IntPtr h, string text, string title, uint flags);
    [DllImport("user32")] internal static extern bool AddClipboardFormatListener(IntPtr h);
    [DllImport("user32")] internal static extern bool RemoveClipboardFormatListener(IntPtr h);
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern IntPtr LoadIcon(IntPtr instance, IntPtr name);
    [DllImport("shell32", CharSet = CharSet.Unicode)] internal static extern bool Shell_NotifyIcon(uint command, ref NOTIFYICONDATA data);
    [DllImport("user32")] internal static extern IntPtr CreatePopupMenu();
    [DllImport("user32", CharSet = CharSet.Unicode)] internal static extern bool AppendMenu(IntPtr menu, uint flags, UIntPtr id, string text);
    [DllImport("user32")] internal static extern bool DestroyMenu(IntPtr menu);
    [DllImport("user32")] internal static extern bool GetCursorPos(out POINT point);
    [DllImport("user32")] internal static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32")] internal static extern uint TrackPopupMenu(IntPtr menu, uint flags, int x, int y, int reserved, IntPtr owner, IntPtr rect);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] internal static extern IntPtr GetModuleHandle(string name);
    [DllImport("kernel32", CharSet = CharSet.Unicode)] internal static extern bool SetDllDirectory(string path);
    [DllImport("kernel32")] internal static extern IntPtr GetCurrentProcess();
    [DllImport("kernel32")] internal static extern bool TerminateProcess(IntPtr process, uint code);
    [DllImport("ole32")] internal static extern int OleInitialize(IntPtr p);
    [DllImport("combase")] internal static extern int RoInitialize(uint type);
}
