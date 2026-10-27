using System;
using System.Diagnostics;
using System.IO;
using System.IO.Compression;
using System.Reflection;
using System.Windows.Forms;
using Microsoft.Win32;

// A single-file installer for an unverified experimental build.
internal static class UniversalSetup
{
    const string Title = "轻剪同步通用测试版";
    [STAThread] static int Main(string[] args)
    {
        try {
            if (Array.IndexOf(args, "--self-check") >= 0) return CheckPayload();
            string miRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "MI");
            if (Process.GetProcessesByName("SyncClipboardLite").Length != 0 || Directory.Exists(Path.Combine(miRoot, "XiaomiPCManager")) || Directory.Exists(Path.Combine(miRoot, "PcContinuity"))) {
                MessageBox.Show("这台电脑已有小米电脑管家或现有轻剪。为避免影响它们，请在另一台非小米电脑上测试。", Title, MessageBoxButtons.OK, MessageBoxIcon.Information); return 2;
            }
            if (!Environment.Is64BitOperatingSystem) throw new InvalidOperationException("需要 64 位 Windows 10 或 11。");
            DialogResult confirm = MessageBox.Show("这是未经非小米电脑实测的通用测试版。安装后需要使用官方入口登录小米账号，并自行验证文字和图片同步。\n\n如果官方组件提示需要修复后台服务，Windows 可能请求管理员授权。\n\n继续选择安装目录？", Title, MessageBoxButtons.OKCancel, MessageBoxIcon.Information);
            if (confirm != DialogResult.OK) return 0;
            string parent;
            using (FolderBrowserDialog dialog = new FolderBrowserDialog()) {
                dialog.Description = "选择用于存放轻剪通用测试版的文件夹，程序会在其中创建 LightClipUniversal 文件夹。";
                dialog.ShowNewFolderButton = true;
                dialog.SelectedPath = Directory.Exists(@"D:\") ? @"D:\" : Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData);
                if (dialog.ShowDialog() != DialogResult.OK) return 0;
                parent = dialog.SelectedPath;
            }
            string target = Path.GetFullPath(Path.Combine(parent, "LightClipUniversal")).TrimEnd(Path.DirectorySeparatorChar);
            foreach (char c in target) if (c > 127) throw new InvalidOperationException("由于小米组件的兼容限制，请选择不含中文的安装目录。推荐 D:\\Apps。 ");
            if (Directory.Exists(target) && Directory.GetFileSystemEntries(target).Length != 0) throw new InvalidOperationException("安装目录已存在且不为空，请选择另一个位置，原有文件没有改动。");
            string linkPath = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.DesktopDirectory), "轻剪同步通用测试版.lnk");
            if (File.Exists(linkPath)) throw new InvalidOperationException("桌面上已有同名快捷方式，请先处理后再安装；原有快捷方式没有改动。");
            using (RegistryKey existing = Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run"))
                if (existing != null && existing.GetValue("LightClipUniversal") != null) throw new InvalidOperationException("已有同名自启动项，请先卸载之前的测试版。");
            Directory.CreateDirectory(target);
            using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip"))
            using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read)) {
                string prefix = target + Path.DirectorySeparatorChar;
                foreach (ZipArchiveEntry entry in archive.Entries) {
                    string path = Path.GetFullPath(Path.Combine(target, entry.FullName.Replace('/', Path.DirectorySeparatorChar)));
                    if (!path.StartsWith(prefix, StringComparison.OrdinalIgnoreCase)) throw new InvalidDataException("安装包路径校验失败。");
                    if (entry.FullName.EndsWith("/", StringComparison.Ordinal)) { Directory.CreateDirectory(path); continue; }
                    Directory.CreateDirectory(Path.GetDirectoryName(path));
                    using (Stream input = entry.Open()) using (FileStream output = new FileStream(path, FileMode.CreateNew, FileAccess.Write, FileShare.None)) input.CopyTo(output);
                }
            }
            string exe = Path.Combine(target, "MiPcContinuity.exe"), icon = Path.Combine(target, "lightclip.ico");
            if (!File.Exists(exe) || !File.Exists(Path.Combine(target, "MiPcContinuity.dll"))) throw new InvalidDataException("安装包组件不完整。");
            dynamic shell = Activator.CreateInstance(Type.GetTypeFromProgID("WScript.Shell"));
            dynamic link = shell.CreateShortcut(linkPath); link.TargetPath = exe; link.WorkingDirectory = target; link.IconLocation = icon + ",0"; link.Save();
            using (RegistryKey key = Registry.CurrentUser.CreateSubKey(@"Software\Microsoft\Windows\CurrentVersion\Run")) key.SetValue("LightClipUniversal", "\"" + exe + "\" --autostart");
            MessageBox.Show("通用测试版已安装到：\n" + target + "\n\n请从桌面打开面板，选择“登录小米账号”。此版本尚未验证同步功能。", Title, MessageBoxButtons.OK, MessageBoxIcon.Information);
            Process.Start(new ProcessStartInfo(exe) { WorkingDirectory = target, UseShellExecute = true });
            return 0;
        } catch (Exception error) {
            MessageBox.Show("安装未完成：" + error.Message, Title, MessageBoxButtons.OK, MessageBoxIcon.Error); return 1;
        }
    }
    static int CheckPayload()
    {
        using (Stream source = Assembly.GetExecutingAssembly().GetManifestResourceStream("payload.zip")) {
            if (source == null) return 1;
            using (ZipArchive archive = new ZipArchive(source, ZipArchiveMode.Read)) {
                foreach (string name in new[] { "MiPcContinuity.exe", "MiPcContinuity.dll", "MiPcContinuity.deps.json", "MiPcContinuity.runtimeconfig.json", "MiSmartShareClrWrapper.dll", "MiSmartShareDLL.dll", "dist_clipboard.dll", "micont_service.exe", "hostfxr.dll", "hostpolicy.dll", "coreclr.dll" })
                    if (archive.GetEntry(name) == null) return 1;
            }
        }
        return 0;
    }
}
