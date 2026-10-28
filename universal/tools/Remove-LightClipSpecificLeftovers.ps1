$ErrorActionPreference = 'Stop'
$exitCode = 0
$target = 'E:\LightClipUniversal-cleanup-e5eddb5002d4456a859f7b011e432f7c'
function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw ('发现链接或重解析点，已停止：' + $Path) }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) { Assert-NoReparse $child.FullName }
    }
}
try {
    $isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $isAdmin) { throw '请右键命令文件，选择“以管理员身份运行”。' }
    $root = [IO.Path]::GetFullPath($target).TrimEnd('\')
    if ($root -ne 'E:\LightClipUniversal-cleanup-e5eddb5002d4456a859f7b011e432f7c') { throw '清理目录校验失败。' }
    if (-not (Test-Path -LiteralPath $root)) { Write-Host '剩余清理目录已不存在，无需删除。'; Read-Host '按回车关闭' | Out-Null; exit 0 }
    $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or -not [String]::Equals($item.FullName.TrimEnd('\'), $root, [StringComparison]::OrdinalIgnoreCase)) { throw '无法确认清理目录。' }
    $ancestor = $item
    while ($ancestor) {
        if (($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '路径包含链接或重解析点，已停止。' }
        $ancestor = $ancestor.Parent
    }
    foreach ($name in @('MiPcContinuityService','micont_service')) {
        $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction Stop
        if ($service) {
            $line = [Environment]::ExpandEnvironmentVariables([string]$service.PathName)
            if ($line.IndexOf('E:\LightClipUniversal\', [StringComparison]::OrdinalIgnoreCase) -ge 0 -or $line.IndexOf($root + '\', [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                throw ('服务仍指向轻剪目录：' + $name + '。请保留目录并反馈。')
            }
        }
    }
    Assert-NoReparse $root
    Add-Type -AssemblyName System.Windows.Forms
    $message = "即将删除上次卸载留下的目录及其中全部剩余文件：`n$root`n`n确认继续？"
    if ([Windows.Forms.MessageBox]::Show($message, '轻剪卸载剩余文件', 'OKCancel', 'Warning') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未删除。' }
    Assert-NoReparse $root
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction Stop
    if (Test-Path -LiteralPath $root) { throw '目录仍然存在。' }
    Write-Host '剩余目录已删除。'
} catch {
    $exitCode = 1
    Write-Host ('剩余目录清理未完成：' + $_.Exception.Message)
    Write-Host '请保留窗口提示并反馈；没有执行权限重置或强制结束其他进程。'
}
Read-Host '按回车关闭' | Out-Null
exit $exitCode
