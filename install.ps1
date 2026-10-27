param([switch]$AutoStart)
$ErrorActionPreference = 'Stop'
# Keep the application and its own data on D:, outside packaged-app caches.
$taskInstall = 'D:\Apps\LightClip'
$taskStartupWasEnabled = $null -ne (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).SyncClipboardLite
if (Get-Process SyncClipboardLite -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq (Join-Path $taskInstall 'SyncClipboardLite.exe') } catch { $false } }) {
    throw '轻剪同步正在运行。请先从托盘选择退出，再运行安装脚本；原管家无需卸载。'
}
& (Join-Path $PSScriptRoot 'build.ps1')
if ($taskInstall -match '[^\x00-\x7F]') { throw '小米原生库的调用方校验不支持当前中文路径。请为本工具选择英文安装路径后再适配。' }
$taskOriginal = 'C:\Program Files\MI\XiaomiPCManager\5.4.0.620\XiaomiPcManager.exe'
if (-not (Test-Path -LiteralPath $taskOriginal)) { throw '没有找到已适配的电脑管家版本 5.4.0.620。' }
$taskSignature = Get-AuthenticodeSignature -LiteralPath $taskOriginal
if ($taskSignature.Status -ne 'Valid' -or $taskSignature.SignerCertificate.Subject -notmatch 'Xiaomi') { throw '原管家宿主签名校验未通过。' }
New-Item -ItemType Directory -Path $taskInstall -Force | Out-Null
Copy-Item -LiteralPath $taskOriginal -Destination (Join-Path $taskInstall 'SyncClipboardLite.exe')
Copy-Item -Path (Join-Path $PSScriptRoot 'dist\*') -Destination $taskInstall -Force
$taskShell = New-Object -ComObject WScript.Shell
$taskShortcut = $taskShell.CreateShortcut('D:\Desktop\轻剪同步.lnk')
$taskShortcut.TargetPath = Join-Path $taskInstall 'SyncClipboardLite.exe'
$taskShortcut.WorkingDirectory = $taskInstall
$taskShortcut.Description = '手机与电脑剪贴板同步，复用本机小米互联服务'
$taskShortcut.IconLocation = (Join-Path $taskInstall 'lightclip.ico') + ',0'
$taskShortcut.Save()
# Read back the saved target so a redirected or broken shortcut fails installation.
$taskShortcut = $taskShell.CreateShortcut('D:\Desktop\轻剪同步.lnk')
$taskShortcutHome = Split-Path -Parent $taskShortcut.TargetPath
if ($taskShortcut.TargetPath -ne (Join-Path $taskInstall 'SyncClipboardLite.exe') -or -not (Test-Path -LiteralPath $taskShortcut.TargetPath)) { throw '快捷方式未正确指向独立安装目录。' }
$taskShortcutIcon = Join-Path $taskShortcutHome 'lightclip-v2.ico'
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'assets\lightclip.ico') -Destination $taskShortcutIcon -Force
$taskShortcut.IconLocation = $taskShortcutIcon + ',0'
$taskShortcut.WorkingDirectory = $taskShortcutHome
$taskShortcut.Save()
if ($AutoStart -or $taskStartupWasEnabled) {
    New-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SyncClipboardLite' -Value ('"' + (Join-Path $taskInstall 'SyncClipboardLite.exe') + '" --autostart') -PropertyType String -Force | Out-Null
}
Write-Output "已安装到：$taskInstall"
Write-Output '原管家的程序文件和自启动设置未修改。'
