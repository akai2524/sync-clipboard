using System;
using System.Drawing;
using System.Drawing.Imaging;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;

// Draws the native panel to a bitmap without launching the app or showing a window.
internal static class AppStorage { internal static string UiErrorFile = Path.Combine(Path.GetTempPath(), "LightClip-panel-probe-error.txt"); }
internal static class PanelRenderProbe
{
    [DllImport("user32")] static extern IntPtr GetDC(IntPtr window);
    [DllImport("user32")] static extern int ReleaseDC(IntPtr window, IntPtr dc);
    [DllImport("gdi32")] static extern bool SetViewportOrgEx(IntPtr dc, int x, int y, out Native.POINT old);
    static readonly BindingFlags Flags = BindingFlags.Static | BindingFlags.NonPublic;
    static void Set(string name, object value) { typeof(TrayFlyout).GetField(name, Flags).SetValue(null, value); }
    static void DrawButton(IntPtr dc, int index, int x, int y, int width, int height)
    {
        Native.POINT previous; SetViewportOrgEx(dc, x, y, out previous);
        UI.DrawItem item = new UI.DrawItem(); item.id = (uint)(200 + index); item.dc = dc; item.rect = new UI.Rect(0, 0, width, height);
        IntPtr pointer = Marshal.AllocHGlobal(Marshal.SizeOf(typeof(UI.DrawItem)));
        try {
            Marshal.StructureToPtr(item, pointer, false);
            typeof(TrayFlyout).GetMethod("DrawButton", Flags).Invoke(null, new object[] { pointer });
        } finally {
            Marshal.FreeHGlobal(pointer); Native.POINT unused; SetViewportOrgEx(dc, previous.x, previous.y, out unused);
        }
    }
    static int Main(string[] args)
    {
        if (args.Length != 3) return 2;
        bool logged = args[1] == "logged";
        Set("state", new FlyoutState { Ready = true, Startup = true, AccountLoggedIn = logged, AccountName = logged ? "示例小米用户" : null, PhoneName = "小米手机", SyncVerified = logged, Memory = 102.4 });
        Set("dark", false); Set("preview", false); Set("scale", 1.0);
        IntPtr icon = UI.LoadImage(IntPtr.Zero, args[2], 1, 64, 64, 0x10); Set("icon", icon);
        IntPtr[] fonts = (IntPtr[])typeof(TrayFlyout).GetField("fonts", Flags).GetValue(null);
        for (int i = 0; i < fonts.Length; i++) {
            int size = i == 0 ? 23 : i == 1 ? 13 : 11;
            fonts[i] = UI.CreateFont(-size, 0, 0, 0, i == 0 ? 600 : 400, 0, 0, 0, 1, 0, 0, 5, 0, "Microsoft YaHei UI");
        }
        IntPtr screen = GetDC(IntPtr.Zero), dc = UI.CreateCompatibleDC(screen), bitmap = UI.CreateCompatibleBitmap(screen, 376, 430), old = UI.SelectObject(dc, bitmap);
        try {
            typeof(TrayFlyout).GetMethod("DrawPanel", Flags).Invoke(null, new object[] { dc });
            DrawButton(dc, 0, 320, 19, 32, 32);
            DrawButton(dc, 1, 24, 314, 328, 56);
            if (!logged) DrawButton(dc, 2, 24, 383, 142, 28);
            DrawButton(dc, 3, 278, 383, 74, 28);
            using (Bitmap image = Image.FromHbitmap(bitmap)) image.Save(args[0], ImageFormat.Png);
        } finally {
            UI.SelectObject(dc, old); UI.DeleteObject(bitmap); UI.DeleteDC(dc); ReleaseDC(IntPtr.Zero, screen);
            foreach (IntPtr font in fonts) if (font != IntPtr.Zero) UI.DeleteObject(font);
            if (icon != IntPtr.Zero) UI.DestroyIcon(icon);
        }
        return 0;
    }
}
