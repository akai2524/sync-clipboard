using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Security.Cryptography;
using System.Threading;
using System.Windows.Forms;
using Microsoft.Win32;

// A single-file installer for an unverified experimental build.
internal static class UniversalSetup
{
    const string Title = "轻剪同步";
    const string PendingName = "setup-incomplete-v1.flag";
    const string PendingValue = "LightClipUniversal-setup-pending-v1";
    [STAThread] static int Main(string[] args)
    {
        try {
            if (Array.IndexOf(args, "--self-check") >= 0) return CheckPayload();
            string miRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "MI");
            if (Process.GetProcessesByName("SyncClipboardLite").Length != 0 || Directory.Exists(Path.Combine(miRoot, "XiaomiPCManager")) || Directory.Exists(Path.Combine(miRoot, "PcContinuity"))) {
                MessageBox.Show("这台电脑已有小米电脑管家或现有轻剪。为避免影响它们，请在另一台非小米电脑上测试。", Title, MessageBoxButtons.OK, MessageBoxIcon.Information); return 2;
            }
            if (!Environment.Is64BitOperatingSystem) throw new InvalidOperationException("需要 64 位 Windows 10 或 11。");
            DialogResult confirm = MessageBox.Show("此安装包适用于非小米 Windows 电脑。安装程序会配置小米互联服务和自动网络规则，并请求管理员授权。\n\nWindows 本地 IPv4 子网中的设备可通过现有物理网卡访问三个小米互联程序，私人和公共网络均生效。手机不需要安装应用，也不需要输入手机 IP。\n\n继续安装？", Title, MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (confirm != DialogResult.OK) return 0;
            string parent;
            using (FolderBrowserDialog dialog = new FolderBrowserDialog()) {
                dialog.Description = "选择用于存放轻剪同步的文件夹，程序会在其中创建 LightClipUniversal 文件夹。";
                dialog.ShowNewFolderButton = true;
                dialog.SelectedPath = Directory.Exists(@"D:\") ? @"D:\" : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (dialog.ShowDialog() != DialogResult.OK) return 0;
                parent = dialog.SelectedPath;
            }
            string target = Path.GetFullPath(Path.Combine(parent, "LightClipUniversal")).TrimEnd(Path.DirectorySeparatorChar);
            foreach (char c in target) if (c > 127) throw new InvalidOperationException("由于小米组件的兼容限制，请选择不含中文的安装目录。推荐 D:\\Apps。 ");
            string exe = Path.Combine(target, "MiPcContinuity.exe"), icon = Path.Combine(target, "lightclip.ico");
            string marker = Path.Combine(target, "data", PendingName);
            bool resume = File.Exists(marker) && File.ReadAllText(marker) == PendingValue;
            if (Directory.Exists(target) && Directory.GetFileSystemEntries(target).Length != 0 && !resume) throw new InvalidOperationException("安装目录已存在且不为空，请先清理旧版或选择另一个位置；原有文件没有改动。");
            string linkPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "轻剪同步.lnk");
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            if (File.Exists(linkPath)) {
                dynamic current = shell.CreateShortcut(linkPath);
                if (!String.Equals((string)current.TargetPath, exe, StringComparison.OrdinalIgnoreCase) || !resume) throw new InvalidOperationException("桌面上已有同名快捷方式，请先处理后再安装；原有快捷方式没有改动。");
            }
            string startup = "\"" + exe + "\" --autostart";
            using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) {
                object value = existing == null ? null : existing.GetValue("LightClipUniversal");
                if (value != null && (!resume || !String.Equals(value as string, startup, StringComparison.OrdinalIgnoreCase))) throw new InvalidOperationException("已有同名自启动项，请先清理旧版；原有设置没有改动。");
            }
            Directory.CreateDirectory(Path.GetDirectoryName(marker));
            if (!resume) File.WriteAllText(marker, PendingValue);
            using (Form progress = new Form()) {
                progress.Text = Title; progress.Width = 440; progress.Height = 125;
                progress.StartPosition = FormStartPosition.CenterScreen; progress.ControlBox = false;
                progress.FormBorderStyle = FormBorderStyle.FixedDialog;
                Label label = new Label(); label.Dock = DockStyle.Fill; label.TextAlign = System.Drawing.ContentAlignment.MiddleCenter;
                progress.Controls.Add(label); progress.Show();
                RunPhase(label, "正在准备程序文件，请稍候……", delegate { ExtractPayload(target, resume); });
                RunPhase(label, "正在配置互联服务和网络，请允许管理员授权……", delegate { ConfigureDependencies(target); });
                progress.Close();
            }
            if (!File.Exists(exe) || !File.Exists(Path.Combine(target, "MiPcContinuity.dll"))) throw new InvalidDataException("安装包组件不完整。");
            dynamic link = shell.CreateShortcut(linkPath); link.TargetPath = exe; link.WorkingDirectory = target; link.IconLocation = icon + ",0"; link.Save();
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) key.SetValue("LightClipUniversal", startup);
            RegisterUninstall(target, icon);
            File.Delete(marker);
            MessageBox.Show("安装及自动网络设置已完成：\n" + target + "\n\n请登录小米账号，并在手机和电脑之间测试文字与图片。", Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
            try { Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = target, UseShellExecute = true }); }
            catch (Exception error) { MessageBox.Show("安装已完成，但程序未能自动打开：" + error.Message + "\n\n请双击桌面上的轻剪快捷方式。", Title, MessageBoxButtons.OK, MessageBoxIcon.Warning); }
            return 0;
        } catch (Exception error) {
            MessageBox.Show("安装未完成：" + error.Message + "\n\n如果已开始安装，请重新运行此安装包并选择相同目录重试。", Title, MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
        }
    }
    static void RegisterUninstall(string target, string icon)
    {
        try {
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Uninstall\LightClipUniversal")) {
                if (key != null) {
                    key.SetValue("DisplayName", Title);
                    key.SetValue("DisplayVersion", "1.0.0");
                    key.SetValue("Publisher", "LightClip");
                    key.SetValue("DisplayIcon", icon + ",0");
                    key.SetValue("InstallLocation", target);
                    string uninstallCmd = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.System), "cmd.exe") + " /c \"" + Path.Combine(target, "卸载轻剪.cmd") + "\"";
                    key.SetValue("UninstallString", uninstallCmd);
                    key.SetValue("QuietUninstallString", uninstallCmd);
                    key.SetValue("NoModify", 1, RegistryValueKind.DWord);
                    key.SetValue("NoRepair", 1, RegistryValueKind.DWord);
                }
            }
        } catch { }
    }
    static void RunPhase(Label label, string message, Action action)
    {
        label.Text = message; Application.DoEvents();
        Exception failure = null;
        Thread worker = new Thread(delegate() { try { action(); } catch (Exception error) { failure = error; } });
        worker.IsBackground = true; worker.Start();
        while (worker.IsAlive) { Application.DoEvents(); Thread.Sleep(50); }
        worker.Join();
        if (failure != null) throw new InvalidOperationException(failure.Message, failure);
    }
    static void ExtractPayload(string root, bool resume)
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
        using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read)) {
            string prefix = root + Path.DirectorySeparatorChar;
            foreach (ZipArchiveEntry entry in archive.Entries) {
                string path = Path.GetFullPath(Path.Combine(root, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包路径校验失败。");
                if (entry.FullName.EndsWith("/", StringComparison.Ordinal)) { Directory.CreateDirectory(path); continue; }
                Directory.CreateDirectory(Path.GetDirectoryName(path));
                if (File.Exists(path)) {
                    if (!resume || !MatchesEntry(path, entry)) throw new InvalidOperationException("发现已有文件与安装包不一致，未覆盖：" + entry.FullName);
                    continue;
                }
                string part = path + ".lightclip-" + Guid.NewGuid().ToString("N") + ".part";
                try {
                    using (Stream input = entry.Open()) using (FileStream output = new FileStream(part, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
                    File.Move(part, path);
                } finally { if (File.Exists(part)) File.Delete(part); }
            }
        }
    }
    static bool MatchesEntry(string path, ZipArchiveEntry entry)
    {
        if (new FileInfo(path).Length != entry.Length) return false;
        using (SHA256 sha = SHA256.Create()) {
            byte[] disk; using (Stream stream = File.OpenRead(path)) disk = sha.ComputeHash(stream);
            byte[] payload; using (Stream stream = entry.Open()) payload = sha.ComputeHash(stream);
            if (disk.Length != payload.Length) return false;
            for (int i = 0; i < disk.Length; i++) if (disk[i] != payload[i]) return false;
            return true;
        }
    }
    static void ConfigureDependencies(string root)
    {
        string script = Path.Combine(root, "tools", "Install-LightClipDependencies.ps1");
        string resultPath = Path.Combine(root, "data", "setup-result-" + Guid.NewGuid().ToString("N") + ".txt");
        ProcessStartInfo start = new ProcessStartInfo(Path.Combine(Environment.SystemDirectory, @"WindowsPowerShell\v1.0\powershell.exe"));
        start.Arguments = "-NoProfile -NonInteractive -ExecutionPolicy Bypass -WindowStyle Hidden -File \"" + script + "\" -InstallPath \"" + root + "\" -ResultPath \"" + resultPath + "\"";
        start.WorkingDirectory = root; start.UseShellExecute = true; start.Verb = "runas"; start.WindowStyle = ProcessWindowStyle.Hidden;
        int code;
        try { using (Process process = Process.Start(start)) { process.WaitForExit(); code = process.ExitCode; } }
        catch (System.ComponentModel.Win32Exception) { throw new InvalidOperationException("未获得管理员授权，无法配置互联服务和网络。"); }
        string detail = File.Exists(resultPath) ? File.ReadAllText(resultPath) : "没有收到设置工具的结果。";
        if (File.Exists(resultPath)) File.Delete(resultPath);
        if (code != 0) throw new InvalidOperationException(detail);
    }
    static int CheckPayload()
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip")) {
            if (source == null) return 1;
            using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read)) {
                foreach (string name in new[] { "MiPcContinuity.exe", "MiPcContinuity.dll", "MiPcContinuity.deps.json", "MiPcContinuity.runtimeconfig.json", "MiSmartShareClrWrapper.dll", "MiSmartShareDLL.dll", "dist_clipboard.dll", "micont_service.exe", "x86/MiPcContinuityService.exe", "tools/Repair-LightClipServices.ps1", "tools/Install-LightClipDependencies.ps1", "tools/Configure-LightClipFirewall.ps1", "tools/Reset-LightClipUniversal.ps1", "tools/LightClipServiceSecurity.ps1", "uninstall.ps1", "卸载轻剪.cmd", "tools/configure-auto-firewall.cmd", "tools/remove-auto-firewall.cmd", "tools/remove-all-firewall.cmd", "tools/Test-AutomaticFirewall.ps1", "tools/test-auto-firewall.cmd", "tools/restore-manual-rules.cmd", "hostfxr.dll", "hostpolicy.dll", "coreclr.dll" })
                    if (archive.GetEntry(name) == null) return 1;
            }
        }
        return 0;
    }
}