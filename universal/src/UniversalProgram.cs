using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Collections.Generic;
using Microsoft.Win32;
using MiSmartShareClrWrapper;
using MiSmartShareClrWrapper.CommonSpace;

// Experimental Windows universal build. Kept independent from the installed Xiaomi-PC build.
internal static class Program
{
    const string Title = "轻剪同步通用测试版";
    const string MutexName = "Local\\LightClipUniversal.Experimental.Instance";
    const string ShowName = "Local\\LightClipUniversal.Experimental.Show";
    const string StopName = "Local\\LightClipUniversal.Experimental.Stop";
    static readonly string HomeDir = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string Exe = Process.GetCurrentProcess().MainModule.FileName;
    static readonly Native.WndProc wndProc = WindowProc;
    static Mutex mutex;
    static EventWaitHandle show, stop;
    static IntPtr window;
    static Assembly wrapper;
    static object main, accountCallbacks, serviceCallbacks, deviceCallbacks;
    static readonly object deviceLock = new object();
    static List<PhoneDevice> phones = new List<PhoneDevice>();
    static Type mainType;
    static bool initialized, stopping;
    static string state = "正在启动";

    [STAThread]
    static int Main(string[] args)
    {
        try {
            if (Array.IndexOf(args, "--self-check") >= 0) return SelfCheck();
            if (Array.IndexOf(args, "--stop") >= 0) { try { using (EventWaitHandle e = EventWaitHandle.OpenExisting(StopName)) e.Set(); } catch (WaitHandleCannotBeOpenedException) { } return 0; }
            // Do not compete with the existing Xiaomi-PC build or manager.
            string miRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "MI");
            if (Process.GetProcessesByName("SyncClipboardLite").Length != 0 || Directory.Exists(Path.Combine(miRoot, "XiaomiPCManager")) || Directory.Exists(Path.Combine(miRoot, "PcContinuity"))) {
                Native.MessageBox(IntPtr.Zero, "通用测试版请在非小米测试电脑上运行。此电脑已有小米电脑管家或现有轻剪，为避免影响它们，测试版已退出。", Title, 0x40);
                return 2;
            }
            bool created;
            mutex = new Mutex(true, MutexName, out created);
            if (!created) { try { using (EventWaitHandle e = EventWaitHandle.OpenExisting(ShowName)) e.Set(); } catch (WaitHandleCannotBeOpenedException) { } return 0; }
            show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowName);
            stop = new EventWaitHandle(false, EventResetMode.ManualReset, StopName);
            SelfCheck(); AppStorage.Initialize(); Native.OleInitialize(IntPtr.Zero); Native.RoInitialize(0);
            UI.SetProcessDpiAwarenessContext(new IntPtr(-4)); CreateWindow();
            TrayFlyout.Initialize(window, CurrentState, ToggleStartup, login => { if (login) Login(); else Native.PostQuitMessage(0); }, false, false);
            Tray(0);
            Native.SetTimer(window, new UIntPtr(1), 1000, IntPtr.Zero);
            Native.SetTimer(window, new UIntPtr(2), 100, IntPtr.Zero);
            Native.MSG message; int result;
            while ((result = Native.GetMessage(out message, IntPtr.Zero, 0, 0)) > 0) {
                if (!TrayFlyout.Dialog(ref message)) { Native.TranslateMessage(ref message); Native.DispatchMessage(ref message); }
            }
            Shutdown(); return result < 0 ? 1 : 0;
        } catch (Exception error) {
            Log("启动异常：" + error.GetType().Name + ": " + error.Message);
            Native.MessageBox(IntPtr.Zero, "通用测试版启动失败：" + error.Message + "\n\n请查看安装目录 data\\logs\\status.log。", Title, 0x10);
            return 1;
        }
    }
    static int SelfCheck()
    {
        if (IntPtr.Size != 8) throw new InvalidOperationException("需要 64 位 Windows。");
        foreach (char c in HomeDir) if (c > 127) throw new InvalidOperationException("安装目录必须只含英文、数字和常用符号。");
        foreach (string file in new[] { "MiSmartShareClrWrapper.dll", "MiSmartShareDLL.dll", "dist_clipboard.dll", "micont_rtm.dll", "micont_service.exe", "coreclr.dll", "hostfxr.dll", "hostpolicy.dll" })
            if (!File.Exists(Path.Combine(HomeDir, file))) throw new FileNotFoundException("组件缺失：" + file);
        return 0;
    }
    static void CreateWindow()
    {
        Native.WNDCLASS cls = new Native.WNDCLASS(); cls.lpfnWndProc = wndProc;
        cls.hInstance = Native.GetModuleHandle(null); cls.lpszClassName = "LightClipUniversal.Experimental.Window";
        if (Native.RegisterClass(ref cls) == 0) throw new System.ComponentModel.Win32Exception();
        window = Native.CreateWindowEx(0x80, cls.lpszClassName, Title, 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (window == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    }
    static void StartBackend()
    {
        state = "正在初始化"; Tray(1);
        Native.SetDllDirectory(HomeDir); Directory.SetCurrentDirectory(HomeDir);
        AppDomain.CurrentDomain.AssemblyResolve += (s,e) => { string file = Path.Combine(HomeDir, new AssemblyName(e.Name).Name + ".dll"); return File.Exists(file) ? Assembly.LoadFrom(file) : null; };
        wrapper = Assembly.LoadFrom(Path.Combine(HomeDir, "MiSmartShareClrWrapper.dll"));
        mainType = wrapper.GetType("MiSmartShareClrWrapper.MiSmartShareWrapper", true);
        main = mainType.GetMethod("GetInstance").Invoke(null, null);
        mainType.GetMethod("InitLog").Invoke(main, null);
        // These are the 14 singleton wrappers present in the inspected universal build.
        foreach (string name in new[] { "CommonSpace.AppSettingWrapper", "CommonSpace.CommonWrapper", "CLRDesktopManagerWrapper",
            "ConnectionClrWrapper", "FirewallWrapper", "LowPowerNotificationBusinessCLRWrapper", "MiAccountBusinessCLRWrapper",
            "MiDropBusinessCLRWrapper", "CommonSpace.HwRadioWrapper", "ClrClipboardSyncWrapper", "event_track_wrapper.OneTrackWrapper",
            "CommonSpace.ServiceCheckerCLrWrapper", "CommonSpace.TrayControlWrapper", "UpdateBusinessCLRWrapper" }) {
            Type type = wrapper.GetType("MiSmartShareClrWrapper." + name, true);
            MethodInfo getter = type.GetMethod("GetInstance", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null);
            if (getter != null) getter.Invoke(null, null);
        }
        AttachCallbacks();
        mainType.GetMethod("Init").Invoke(main, new object[] { "clip" });
        initialized = true; state = "互联库已启动，剪贴板待实测"; Log(state); Tray(1);
        try { MiAccountBusinessCLRWrapper.GetInstance().HandleGetLoginStatus(); }
        catch (Exception e) { Log("读取登录状态失败：" + e.GetType().Name); }
        RefreshDevices();
        if (Array.IndexOf(Environment.GetCommandLineArgs(), "--autostart") < 0) TrayFlyout.Show();
    }
    static void AttachCallbacks()
    {
        accountCallbacks = new AccountCallbacks(); serviceCallbacks = new ServiceCallbacks();
        MiAccountBusinessCLRWrapper.GetInstance().SetMiAccountUICLRWrapperPtr((MiAccountUICLRWrapper)accountCallbacks);
        ServiceCheckerCLrWrapper.GetInstance().AddUI((IServiceCheckerWrapperUI)serviceCallbacks);
        deviceCallbacks = new DeviceCallbacks();
        ConnectionClrWrapper.GetInstance().AddUI((ConnectionUIWrapper)deviceCallbacks);
    }
    static void RefreshDevices()
    {
        try { ConnectionClrWrapper.GetInstance().HandleGetDeviceList(); }
        catch (Exception e) { Log("获取设备列表失败：" + e.GetType().Name); }
    }
    internal static void UpdateDevices(IEnumerable<DeviceInfoWrapper> devices)
    {
        List<PhoneDevice> found = new List<PhoneDevice>();
        if (devices != null) foreach (DeviceInfoWrapper device in devices) {
            if (device.device_type != CDeviceTypeWrapper.kPhone || String.IsNullOrEmpty(device.idhash)) continue;
            string name = !String.IsNullOrWhiteSpace(device.name) ? device.name : !String.IsNullOrWhiteSpace(device.market_name) ? device.market_name : "小米手机";
            found.Add(new PhoneDevice { Id = device.idhash, Name = name.Replace("&", "&&"), Online = device.is_online });
        }
        lock (deviceLock) phones = found;
        Log("设备列表已更新，手机数量：" + found.Count);
        if (window != IntPtr.Zero) Native.PostMessage(window, 0x8004, IntPtr.Zero, IntPtr.Zero);
    }
    static void Login()
    {
        if (!initialized) { Native.MessageBox(window, "互联组件尚未启动，请稍后重试。", Title, 0x40); return; }
        try { Log("用户请求官方登录界面"); MiAccountBusinessCLRWrapper.GetInstance().HandleLogin(LoginWayWrapper.KNormal); }
        catch (Exception e) { Log("登录入口失败：" + e.GetType().Name); Native.MessageBox(window, "无法打开小米登录入口：" + e.Message, Title, 0x10); }
    }
    internal static void AccountEvent(string value, bool success)
    {
        state = value; Log(value); if (window != IntPtr.Zero) Native.PostMessage(window, 0x8002, new IntPtr(success ? 1 : 0), IntPtr.Zero);
    }
    internal static void ServiceEvent(string value, bool repair)
    {
        state = value; Log(value); if (window != IntPtr.Zero) Native.PostMessage(window, repair ? 0x8003u : 0x8002u, IntPtr.Zero, IntPtr.Zero);
    }
    static IntPtr WindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        try {
            if (msg == 0x113 && w.ToInt64() == 2) { Native.KillTimer(h, new UIntPtr(2)); StartBackend(); return IntPtr.Zero; }
            if (msg == 0x113 && w.ToInt64() == 1) { if (show.WaitOne(0)) TrayFlyout.Show(); if (stop.WaitOne(0)) Native.PostQuitMessage(0); return IntPtr.Zero; }
            if (msg == 0x8001) { int action = (int)l.ToInt64(); if (action == 0x202) TrayFlyout.Toggle(); else if (action == 0x205) ShowMenu(); return IntPtr.Zero; }
            if (msg == 0x8002) {
                Tray(1); TrayFlyout.Changed();
                if (w != IntPtr.Zero) { try { ClrClipboardSyncWrapper.GetInstance().HandleSetClipBoardSyncSwitch(true); } catch (Exception e) { Log("启用剪贴板失败：" + e.GetType().Name); } RefreshDevices(); }
                return IntPtr.Zero;
            }
            if (msg == 0x8004) { TrayFlyout.Changed(); return IntPtr.Zero; }
            if (msg == 0x8003) {
                Tray(1); TrayFlyout.Changed();
                if (Native.MessageBox(h, "官方互联组件报告后台服务需要修复。是否打开小米自带的服务修复流程？\n\n可能出现 Windows 管理员授权。", Title, 0x24) == 6)
                    ServiceCheckerCLrWrapper.GetInstance().HandleRepairService();
                return IntPtr.Zero;
            }
            if (msg == Native.RegisterWindowMessage("TaskbarCreated")) { Tray(0); return IntPtr.Zero; }
        } catch (Exception error) {
            Log("运行异常：" + error.GetType().Name + ": " + error.Message);
            Native.MessageBox(h, "通用测试版遇到错误：" + error.Message, Title, 0x10);
            Native.PostQuitMessage(1);
        }
        return Native.DefWindowProc(h, msg, w, l);
    }
    static void Tray(uint command)
    {
        Native.NOTIFYICONDATA d = new Native.NOTIFYICONDATA(); d.cbSize = Marshal.SizeOf(typeof(Native.NOTIFYICONDATA)); d.hWnd = window;
        d.uID = 1; d.uFlags = 7; d.uCallbackMessage = 0x8001; d.hIcon = TrayFlyout.SmallIcon; d.szTip = Title + "：" + state;
        Native.Shell_NotifyIcon(command, ref d);
    }
    static FlyoutState CurrentState()
    {
        string label; lock (deviceLock) label = phones.Count == 0 ? "未发现手机" : phones.Count == 1 ? phones[0].Name.Replace("&&", "&") : "发现 " + phones.Count + " 台手机";
        using (Process p = Process.GetCurrentProcess()) return new FlyoutState { Ready = initialized, Startup = StartupEnabled(), PhoneName = label, Memory = p.WorkingSet64 / 1048576.0 };
    }
    static bool StartupEnabled() { using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) return k != null && k.GetValue("LightClipUniversal") != null; }
    static void ToggleStartup()
    {
        bool enabled = StartupEnabled();
        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
            if (enabled) k.DeleteValue("LightClipUniversal", false); else k.SetValue("LightClipUniversal", "\"" + Exe + "\" --autostart");
        }
    }
    static void ShowMenu()
    {
        IntPtr menu = Native.CreatePopupMenu();
        try {
            Native.AppendMenu(menu, 0, new UIntPtr(1), "打开面板"); Native.AppendMenu(menu, 0, new UIntPtr(2), "登录小米账号");
            Native.AppendMenu(menu, 0, new UIntPtr(3), "查看状态"); Native.AppendMenu(menu, 0, new UIntPtr(4), "退出"); Native.AppendMenu(menu, 0, new UIntPtr(5), "刷新并选择手机");
            Native.POINT p; Native.GetCursorPos(out p); Native.SetForegroundWindow(window);
            uint choice = Native.TrackPopupMenu(menu, 0x102, p.x, p.y, 0, window, IntPtr.Zero);
            if (choice == 1) TrayFlyout.Show(); else if (choice == 2) Login();
            else if (choice == 3) Native.MessageBox(window, state + "\n\n请在手机和电脑之间实际测试文字及图片复制；界面不代表传输成功。", Title, 0x40);
            else if (choice == 4) Native.PostQuitMessage(0);
            else if (choice == 5) ChoosePhone();
        } finally { Native.DestroyMenu(menu); }
    }
    static void ChoosePhone()
    {
        if (!initialized) { Native.MessageBox(window, "互联组件尚未启动，请稍后重试。", Title, 0x40); return; }
        RefreshDevices();
        PhoneDevice[] snapshot; lock (deviceLock) snapshot = phones.ToArray();
        if (snapshot.Length == 0) { Native.MessageBox(window, "暂未发现手机。请确认手机和电脑登录同一小米账号，开启互联相关功能，并稍后再次选择。", Title, 0x40); return; }
        IntPtr menu = Native.CreatePopupMenu();
        try {
            for (int i = 0; i < snapshot.Length && i < 50; i++) Native.AppendMenu(menu, 0, new UIntPtr((uint)(i + 1)), snapshot[i].Name + (snapshot[i].Online ? "（在线）" : "（离线）"));
            Native.POINT p; Native.GetCursorPos(out p); Native.SetForegroundWindow(window);
            uint choice = Native.TrackPopupMenu(menu, 0x102, p.x, p.y, 0, window, IntPtr.Zero);
            if (choice > 0 && choice <= snapshot.Length) {
                string id = snapshot[choice - 1].Id; bool present = false;
                lock (deviceLock) foreach (PhoneDevice phone in phones) if (phone.Id == id) { present = true; break; }
                if (!present) { Native.MessageBox(window, "设备列表已变化，请重新选择手机。", Title, 0x40); return; }
                ConnectionClrWrapper.GetInstance().HandleUpdateSelectDevice(id);
                state = "已请求选择手机，剪贴板待实测"; Log(state); Tray(1);
            }
        } finally { Native.DestroyMenu(menu); }
    }
    static void Shutdown()
    {
        if (stopping) return; stopping = true; Tray(2); TrayFlyout.Dispose(); Log("退出");
        new Thread(() => { Thread.Sleep(8000); Native.TerminateProcess(Native.GetCurrentProcess(), 0); }) { IsBackground = true }.Start();
        if (initialized) try { mainType.GetMethod("UnInit").Invoke(main, null); } catch { }
        if (window != IntPtr.Zero) Native.DestroyWindow(window);
        if (mutex != null) mutex.ReleaseMutex(); Environment.Exit(0);
    }
    static void Log(string text)
    {
        try { Directory.CreateDirectory(AppStorage.LogDirectory); File.AppendAllText(AppStorage.LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + text + Environment.NewLine, new UTF8Encoding(false)); } catch { }
    }
}

internal sealed class PhoneDevice { internal string Id, Name; internal bool Online; }
internal sealed class DeviceCallbacks : ConnectionUIWrapper
{
    public void OnUpdateDeviceList(IEnumerable<DeviceInfoWrapper> devices) { Program.UpdateDevices(devices); }
}

internal sealed class AccountCallbacks : MiAccountUICLRWrapper
{
    public void OnLoginExpose() { Program.AccountEvent("请登录小米账号", false); }
    public void OnMiAccountToBeConfirmed(string id, string name, string avatar) { Program.AccountEvent("等待账号确认", false); }
    public void OnShowDisconnectWarning() { Program.AccountEvent("账号连接需要确认", false); }
    public void OnLoginSuccess(string id, string name, string avatar) { Program.AccountEvent("小米账号登录成功；同步待实测", true); }
    public void OnLogout() { Program.AccountEvent("账号已退出", false); }
    public void OnLoginFailed() { Program.AccountEvent("小米账号登录失败", false); }
}
internal sealed class ServiceCallbacks : IServiceCheckerWrapperUI
{
    public void OnMiServiceStateChange(bool connected) { if (!connected) Program.ServiceEvent("小米互联服务不可用", false); }
    public void OnShowMiServiceError() { Program.ServiceEvent("小米互联服务需要修复", true); }
    public void OnShowSvrError(ServiceTypeWrapper service) { Program.ServiceEvent("小米后台服务需要修复", true); }
    public void OnRepairServiceSuccess(ServiceTypeWrapper service) { Program.ServiceEvent("服务修复已返回；同步待实测", false); }
}
internal static class AppStorage
{
    static readonly string Data = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data");
    internal static readonly string LogDirectory = Path.Combine(Data, "logs");
    internal static readonly string LogFile = Path.Combine(LogDirectory, "status.log");
    internal static readonly string UiErrorFile = Path.Combine(LogDirectory, "ui-error.txt");
    internal static void Initialize() { Directory.CreateDirectory(LogDirectory); Directory.CreateDirectory(Path.Combine(Data, "temp")); Environment.SetEnvironmentVariable("TEMP", Path.Combine(Data, "temp")); Environment.SetEnvironmentVariable("TMP", Path.Combine(Data, "temp")); }
}
