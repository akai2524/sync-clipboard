using System;
using System.Diagnostics;
using System.IO;
using System.Reflection;
using System.Runtime.InteropServices;
using System.Security.Cryptography;
using System.Text;
using System.Threading;
using Microsoft.Win32;

// This host uses the user's installed Xiaomi libraries. It does not modify them.
// Build with the Windows .NET Framework compiler; execute using the .NET 8 apphost.
internal static class Program
{
    const string Title = "轻剪同步";
    const string EventName = "Local\\SyncClipboardLite.Stop";
    const string RestoreName = "Local\\SyncClipboardLite.Restore";
    const string ShowName = "Local\\SyncClipboardLite.Show";
    const string MutexName = "Local\\SyncClipboardLite.Instance";
    const string BackendVersion = "5.4.0.620";
    const string NativeHash = "5F849FE57DF16545DF2E80B4F226E30E6852014ED2AD4DE10CE8F957C2F2F0C1";
    static readonly string Home = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string Backend = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "MI", "XiaomiPCManager", BackendVersion);
    static readonly string Manager = Path.Combine(Backend, "XiaomiPcManager.exe");
    static readonly string Exe = Process.GetCurrentProcess().MainModule.FileName;
    static readonly string LogFile = AppStorage.LogFile;
    static Mutex mutex;
    static EventWaitHandle stop, restore, show;
    static Native.WndProc wndProc = WindowProc;
    static IntPtr window;
    static Assembly wrapper;
    static object main;
    static Type mainType;
    static string phase = "正在启动";
    static bool initialized, shuttingDown, managerWasRunning, restoreOnExit;
    static int changes;
    static DateTime lastChange;
    static DateTime startTime = DateTime.UtcNow;
    static int delaySeconds;
    static readonly string[] WrapperNames = {
        "CommonSpace.AppSettingWrapper", "AudioShareBusinessCLRWrapper", "CameraCooperationWrapper",
        "CommonSpace.CommonWrapper", "CLRDesktopManagerWrapper", "DeviceInfoBusinessCLRWrapper",
        "DistFileBusinessCLRWrapper", "EarphoneBusinessWrapper", "EarphoneBusinessContext",
        "ConnectionClrWrapper", "FirewallWrapper", "CLRHandoffWrapper", "DeviceRingWrapper",
        "LowPowerNotificationBusinessCLRWrapper", "MiAccountBusinessCLRWrapper", "MiDropBusinessCLRWrapper",
        "CommonSpace.HwRadioWrapper", "ClrClipboardSyncWrapper", "MiracastWrapper", "MiTrustBusinessCLRWrapper",
        "NetCollabBusinessCLRWrapper", "NFCShareBusinessCLRWrapper", "event_track_wrapper.OneTrackWrapper",
        "PadShareWrapper", "DragDropWrapper", "MouseTriggerPadShareWrapper", "PadCoopWrapper",
        "RelayMessageWrapper", "CLRSearchManagerWrapper", "CommonSpace.ServiceCheckerCLrWrapper",
        "SysNotificationWrapper", "TelephoneCooperationWrapper", "CommonSpace.TrayControlWrapper", "UpdateBusinessCLRWrapper"
    };

    [STAThread]
    static int Main(string[] args)
    {
        try {
            if (Has(args, "--ui-preview") || Has(args, "--ui-preview-dark")) { AppStorage.Initialize(); return TrayFlyout.Preview(Has(args, "--ui-preview-dark")); }
            if (Has(args, "--restore-after")) { RestoreAfter(args); return 0; }
            if (Has(args, "--stop") || Has(args, "--restore")) {
                if (Has(args, "--restore")) Signal(RestoreName);
                Signal(EventName); return 0;
            }
            if (Has(args, "--check")) {
                Validate(); Console.WriteLine("CHECK_OK version=" + BackendVersion + " ascii_path=true native_hash=true"); return 0;
            }
            bool created;
            mutex = new Mutex(true, MutexName, out created);
            if (!created) { Signal(ShowName); return 0; }
            stop = new EventWaitHandle(false, EventResetMode.ManualReset, EventName);
            restore = new EventWaitHandle(false, EventResetMode.ManualReset, RestoreName);
            show = new EventWaitHandle(false, EventResetMode.AutoReset, ShowName);
            Validate();
            AppStorage.Initialize();
            Native.OleInitialize(IntPtr.Zero);
            Native.RoInitialize(0);
            UI.SetProcessDpiAwarenessContext(new IntPtr(-4));
            CreateWindow();
            TrayFlyout.Initialize(window, GetFlyoutState, ToggleStartup,
                restoreManager => { restoreOnExit = restoreManager; Native.PostQuitMessage(0); }, false, false);
            Native.AddClipboardFormatListener(window);
            Tray(0);
            delaySeconds = Has(args, "--autostart") ? 30 : 0;
            Native.SetTimer(window, new UIntPtr(1), 1000, IntPtr.Zero);
            Native.SetTimer(window, new UIntPtr(2), 100, IntPtr.Zero);
            Log("启动；互联库版本 " + BackendVersion);
            Log("本进程临时目录：" + Path.GetTempPath());
            Native.MSG msg;
            int result;
            while ((result = Native.GetMessage(out msg, IntPtr.Zero, 0, 0)) > 0) {
                if (!TrayFlyout.Dialog(ref msg)) { Native.TranslateMessage(ref msg); Native.DispatchMessage(ref msg); }
            }
            Shutdown();
            return result < 0 ? 1 : 0;
        } catch (Exception ex) {
            Log("启动失败：" + ex.GetType().Name);
            if (managerWasRunning) StartManager();
            Native.MessageBox(IntPtr.Zero, "启动失败：" + ex.Message + "\n\n原电脑管家的文件和设置未改动。", Title, 0x10);
            return 1;
        }
    }

    static bool Has(string[] args, string value) { return Array.IndexOf(args, value) >= 0; }
    static void Validate()
    {
        if (IntPtr.Size != 8) throw new InvalidOperationException("仅支持 Windows 64 位系统。");
        foreach (char c in Home) if (c > 127) throw new InvalidOperationException("小米互联库的调用方校验在中文路径下可能失败。请运行 install.ps1 安装至英文路径。");
        if (!File.Exists(Manager)) throw new FileNotFoundException("没有找到已适配的小米电脑管家 " + BackendVersion + "。请勿通过替换原管家文件安装。");
        Version supported = new Version(BackendVersion);
        foreach (string directory in Directory.GetDirectories(Path.GetDirectoryName(Backend))) {
            Version candidate;
            if (Version.TryParse(Path.GetFileName(directory), out candidate) && candidate > supported && File.Exists(Path.Combine(directory, "XiaomiPcManager.exe")))
                throw new InvalidOperationException("检测到更高版本的小米电脑管家，需要重新适配；当前未退出原管家。");
        }
        using (SHA256 sha = SHA256.Create()) using (FileStream f = File.OpenRead(Path.Combine(Backend, "MiSmartShareDLL.dll"))) {
            string hash = BitConverter.ToString(sha.ComputeHash(f)).Replace("-", "");
            if (hash != NativeHash) throw new InvalidOperationException("互联库与已测试版本不一致，已停止加载，需要重新适配。");
        }
    }

    static void StartBackend()
    {
        phase = "正在连接小米互联服务"; Tray(1);
        managerWasRunning = ManagerRunning();
        foreach (string name in new[] { "XiaomiPcManager", "PcClipboard", "MiPCAudio", "MiSmartShareHandoff" }) {
            foreach (Process p in Process.GetProcessesByName(name)) {
                using (p) try {
                    if (p.MainModule.FileName.StartsWith(Backend + Path.DirectorySeparatorChar, StringComparison.OrdinalIgnoreCase)) {
                        p.Kill(); p.WaitForExit(3000);
                    }
                } catch (System.ComponentModel.Win32Exception) { throw new InvalidOperationException("无法退出原管家进程，请先在托盘中退出管家，再启动本程序。"); }
            }
        }
        Native.SetDllDirectory(Backend);
        Directory.SetCurrentDirectory(Backend);
        AppDomain.CurrentDomain.AssemblyResolve += Resolve;
        wrapper = Assembly.LoadFrom(Path.Combine(Backend, "MiSmartShareClrWrapper.dll"));
        mainType = wrapper.GetType("MiSmartShareClrWrapper.MiSmartShareWrapper", true);
        main = mainType.GetMethod("GetInstance").Invoke(null, null);
        mainType.GetMethod("InitLog").Invoke(main, null);
        // Creating the adapters installs safe native callbacks. Omitting the camera
        // adapter, for example, causes an access violation during device enumeration.
        // No Xiaomi GUI assemblies, clipboard history app or WebView are loaded here.
        foreach (string name in WrapperNames) {
            Type type = wrapper.GetType("MiSmartShareClrWrapper." + name, true);
            MethodInfo getter = type.GetMethod("GetInstance", BindingFlags.Public | BindingFlags.Static, null, Type.EmptyTypes, null);
            if (getter != null) getter.Invoke(null, null);
        }
        try {
            DeviceNames.Attach(wrapper, () => Native.PostMessage(window, 0x8002, IntPtr.Zero, IntPtr.Zero));
            Log("已订阅小米互联设备信息和名称更新回调");
        } catch (Exception ex) { Log("设备名称回调不可用：" + ex.GetType().Name); }
        mainType.GetMethod("Init").Invoke(main, new object[] { "clip" });
        initialized = true;
        try { DeviceNames.Request(); } catch (Exception ex) { Log("设备列表查询不可用：" + ex.GetType().Name); }
        phase = "互联库已启动";
        Tray(1); Log("互联库初始化返回；此状态不等于手机端已确认同步成功");
        WriteStatus();
    }

    static Assembly Resolve(object sender, ResolveEventArgs e)
    {
        string path = Path.Combine(Backend, new AssemblyName(e.Name).Name + ".dll");
        return File.Exists(path) ? Assembly.LoadFrom(path) : null;
    }

    static bool ManagerRunning()
    {
        foreach (Process p in Process.GetProcessesByName("XiaomiPcManager")) using (p) {
            try { if (string.Equals(p.MainModule.FileName, Manager, StringComparison.OrdinalIgnoreCase)) return true; } catch { }
        }
        return false;
    }

    static void CreateWindow()
    {
        Native.WNDCLASS cls = new Native.WNDCLASS();
        cls.lpfnWndProc = wndProc; cls.hInstance = Native.GetModuleHandle(null); cls.lpszClassName = "SyncClipboardLite.Window";
        if (Native.RegisterClass(ref cls) == 0) throw new System.ComponentModel.Win32Exception();
        window = Native.CreateWindowEx(0x80, cls.lpszClassName, Title, 0, 0, 0, 0, 0, IntPtr.Zero, IntPtr.Zero, cls.hInstance, IntPtr.Zero);
        if (window == IntPtr.Zero) throw new System.ComponentModel.Win32Exception();
    }

    static IntPtr WindowProc(IntPtr h, uint msg, IntPtr w, IntPtr l)
    {
        try {
            if (msg == 0x113) {
                if (w.ToInt64() == 2) {
                    Native.KillTimer(h, new UIntPtr(2));
                    if (delaySeconds == 0) StartBackend();
                    else { phase = "等待登录后接管"; Tray(1); }
                } else {
                    if (show.WaitOne(0)) TrayFlyout.Show();
                    if (restore.WaitOne(0)) restoreOnExit = true;
                    if (stop.WaitOne(0)) Native.PostQuitMessage(0);
                    if (delaySeconds > 0 && --delaySeconds == 0) StartBackend();
                    // If the user deliberately opens the original manager, yield to it.
                    if (initialized && ManagerRunning()) { Log("检测到原管家启动，退出并让出互联连接"); Native.PostQuitMessage(0); }
                }
                return IntPtr.Zero;
            }
            if (msg == 0x31d) { changes++; lastChange = DateTime.Now; WriteStatus(); TrayFlyout.Changed(); return IntPtr.Zero; }
            if (msg == 0x8002) { WriteStatus(); TrayFlyout.Changed(); return IntPtr.Zero; }
            if (msg == 0x8001) {
                int action = (int)l.ToInt64();
                if (action == 0x205) ShowMenu();
                if (action == 0x202) TrayFlyout.Toggle();
                return IntPtr.Zero;
            }
            if (msg == Native.RegisterWindowMessage("TaskbarCreated")) { Tray(0); return IntPtr.Zero; }
        } catch (Exception ex) {
            Log("运行失败：" + ex.GetType().Name);
            Native.MessageBox(h, "运行失败：" + ex.Message + "\n将退出并恢复原管家。", Title, 0x10);
            restoreOnExit = managerWasRunning;
            Native.PostQuitMessage(1);
        }
        return Native.DefWindowProc(h, msg, w, l);
    }

    static void Tray(uint command)
    {
        Native.NOTIFYICONDATA data = new Native.NOTIFYICONDATA();
        data.cbSize = Marshal.SizeOf(typeof(Native.NOTIFYICONDATA)); data.hWnd = window; data.uID = 1;
        data.uFlags = 7; data.uCallbackMessage = 0x8001; data.hIcon = TrayFlyout.SmallIcon;
        data.szTip = Title + "：" + phase;
        Native.Shell_NotifyIcon(command, ref data);
    }

    static bool StartupEnabled()
    {
        using (RegistryKey k = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
            return k != null && k.GetValue("SyncClipboardLite") != null;
    }
    static void ToggleStartup()
    {
        bool enabled = StartupEnabled();
        using (RegistryKey k = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
            if (enabled) k.DeleteValue("SyncClipboardLite", false);
            else k.SetValue("SyncClipboardLite", "\"" + Exe + "\" --autostart", RegistryValueKind.String);
        }
        Log(enabled ? "关闭本工具的登录自启动" : "开启本工具的登录自启动");
    }
    static void ShowMenu()
    {
        IntPtr menu = Native.CreatePopupMenu();
        try {
            Native.AppendMenu(menu, 0, new UIntPtr(1), "查看状态");
            Native.AppendMenu(menu, StartupEnabled() ? 8u : 0u, new UIntPtr(3), "随 Windows 登录启动");
            Native.AppendMenu(menu, 0, new UIntPtr(4), "切回小米电脑管家");
            Native.AppendMenu(menu, 0, new UIntPtr(5), "退出轻剪同步");
            Native.POINT point; Native.GetCursorPos(out point); Native.SetForegroundWindow(window);
            uint choice = Native.TrackPopupMenu(menu, 0x102, point.x, point.y, 0, window, IntPtr.Zero);
            if (choice == 1) ShowStatus();
            if (choice == 3) ToggleStartup();
            if (choice == 4) { restoreOnExit = true; Native.PostQuitMessage(0); }
            if (choice == 5) Native.PostQuitMessage(0);
            Native.PostMessage(window, 0, IntPtr.Zero, IntPtr.Zero);
        } finally { Native.DestroyMenu(menu); }
    }
    static string StatusText()
    {
        using (Process p = Process.GetCurrentProcess()) {
            return phase + "\n\n本进程工作集：" + (p.WorkingSet64 / 1048576.0).ToString("F1") + " MB" +
                "\n本进程私有提交：" + (p.PrivateMemorySize64 / 1048576.0).ToString("F1") + " MB" +
                "\n以上不含小米后台服务。\n手机名称：" + DeviceNames.Label + "\n名称来源：" + DeviceNames.Source + "\n剪贴板变化次数：" + changes +
                "\n最近变化：" + (lastChange == default(DateTime) ? "暂无" : lastChange.ToString("HH:mm:ss")) +
                "\n\n同步状态请通过手机实测确认；变化次数也包含电脑本地复制。\n依赖已安装的小米互联组件 " + BackendVersion + "。" +
                "\n数据目录：" + AppStorage.DataDirectory + "\n本进程临时目录：" + Path.GetTempPath();
        }
    }
    static FlyoutState GetFlyoutState()
    {
        using (Process p = Process.GetCurrentProcess()) return new FlyoutState {
            Ready = initialized, Startup = StartupEnabled(), Phase = phase, Changes = changes, PhoneName = DeviceNames.Label,
            LastChange = lastChange, Memory = p.WorkingSet64 / 1048576.0
        };
    }
    static void ShowStatus() { TrayFlyout.Show(); }
    static void WriteStatus() { try { File.WriteAllText(AppStorage.StatusFile, StatusText(), new UTF8Encoding(false)); } catch { } }

    static void Shutdown()
    {
        if (shuttingDown) return; shuttingDown = true;
        Tray(2); Native.RemoveClipboardFormatListener(window);
        TrayFlyout.Dispose();
        if (restoreOnExit) {
            ProcessStartInfo helper = new ProcessStartInfo(Exe, "--restore-after " + Process.GetCurrentProcess().Id) { WorkingDirectory = Home, UseShellExecute = false, CreateNoWindow = true };
            AppStorage.RestoreEnvironment(helper);
            Process.Start(helper);
        }
        Log("正在退出" + (restoreOnExit ? "，退出后恢复管家" : ""));
        // A native shutdown can block. Do not leave a hung process consuming memory.
        new Thread(() => { Thread.Sleep(8000); Native.TerminateProcess(Native.GetCurrentProcess(), 0); }) { IsBackground = true }.Start();
        if (initialized) try { mainType.GetMethod("UnInit").Invoke(main, null); } catch { }
        if (window != IntPtr.Zero) Native.DestroyWindow(window);
        if (mutex != null) { mutex.ReleaseMutex(); mutex.Dispose(); mutex = null; }
        Environment.Exit(0);
    }
    static void Signal(string name) { try { using (EventWaitHandle e = EventWaitHandle.OpenExisting(name)) e.Set(); } catch (WaitHandleCannotBeOpenedException) { } }
    static void RestoreAfter(string[] args)
    {
        int i = Array.IndexOf(args, "--restore-after"), pid;
        if (i + 1 < args.Length && int.TryParse(args[i + 1], out pid)) try { using (Process p = Process.GetProcessById(pid)) p.WaitForExit(15000); } catch (ArgumentException) { }
        StartManager();
    }
    static void StartManager()
    {
        if (!File.Exists(Manager) || ManagerRunning()) return;
        ProcessStartInfo manager = new ProcessStartInfo(Manager) { WorkingDirectory = Backend, UseShellExecute = false, CreateNoWindow = true, WindowStyle = ProcessWindowStyle.Hidden };
        AppStorage.RestoreEnvironment(manager);
        Process.Start(manager);
    }
    static void Log(string line)
    {
        try {
            Directory.CreateDirectory(AppStorage.LogDirectory);
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 16384) File.Copy(LogFile, LogFile + ".1", true);
            if (File.Exists(LogFile) && new FileInfo(LogFile).Length > 16384) File.WriteAllText(LogFile, "");
            File.AppendAllText(LogFile, DateTime.Now.ToString("yyyy-MM-dd HH:mm:ss") + " " + line + Environment.NewLine, new UTF8Encoding(false));
        } catch { }
    }
}

internal static class AppStorage
{
    internal static readonly string DataDirectory = Path.Combine(AppDomain.CurrentDomain.BaseDirectory, "data");
    internal static readonly string LogDirectory = Path.Combine(DataDirectory, "logs");
    internal static readonly string CacheDirectory = Path.Combine(DataDirectory, "cache");
    internal static readonly string TempDirectory = Path.Combine(DataDirectory, "temp");
    internal static readonly string LogFile = Path.Combine(LogDirectory, "status.log");
    internal static readonly string UiErrorFile = Path.Combine(LogDirectory, "ui-error.txt");
    internal static readonly string StatusFile = Path.Combine(DataDirectory, "status.txt");
    static readonly string OriginalTemp = Environment.GetEnvironmentVariable("TEMP");
    static readonly string OriginalTmp = Environment.GetEnvironmentVariable("TMP");

    internal static void Initialize()
    {
        Directory.CreateDirectory(LogDirectory);
        Directory.CreateDirectory(CacheDirectory);
        Directory.CreateDirectory(TempDirectory);
        // Only this process and its own work inherit these values. User/system settings stay intact.
        Environment.SetEnvironmentVariable("TEMP", TempDirectory, EnvironmentVariableTarget.Process);
        Environment.SetEnvironmentVariable("TMP", TempDirectory, EnvironmentVariableTarget.Process);
    }
    internal static void RestoreEnvironment(ProcessStartInfo process)
    {
        if (OriginalTemp == null) process.EnvironmentVariables.Remove("TEMP"); else process.EnvironmentVariables["TEMP"] = OriginalTemp;
        if (OriginalTmp == null) process.EnvironmentVariables.Remove("TMP"); else process.EnvironmentVariables["TMP"] = OriginalTmp;
    }
}

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
