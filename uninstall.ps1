$ErrorActionPreference = 'Stop'
$taskInstall = 'D:\Apps\LightClip'
$taskExe = Join-Path $taskInstall 'SyncClipboardLite.exe'
if (Test-Path -LiteralPath $taskExe) {
    $taskStopper = Start-Process -FilePath $taskExe -ArgumentList '--restore' -WindowStyle Hidden -PassThru
    $taskStopper.WaitForExit(5000) | Out-Null
    $taskUntil = (Get-Date).AddSeconds(20)
    do {
        $taskRunning = @(Get-Process SyncClipboardLite -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $taskExe } catch { $false } })
        if ($taskRunning.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $taskUntil)
    if ($taskRunning.Count -gt 0) { throw '本工具仍在退出，未删除任何安装文件。请稍后重试。' }
}
Remove-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'SyncClipboardLite' -ErrorAction SilentlyContinue
$taskShortcut = 'D:\Desktop\轻剪同步.lnk'
if (Test-Path -LiteralPath $taskShortcut) {
    $taskShell = New-Object -ComObject WScript.Shell
    $taskLink = $taskShell.CreateShortcut($taskShortcut)
    if ($taskLink.TargetPath -eq $taskExe) { Remove-Item -LiteralPath $taskShortcut }
}
if (Test-Path -LiteralPath $taskInstall) {
    $taskResolved = [IO.Path]::GetFullPath($taskInstall).TrimEnd('\')
    $taskExpected = [IO.Path]::GetFullPath('D:\Apps\LightClip').TrimEnd('\')
    if ($taskResolved -ne $taskExpected -or (Get-Item -LiteralPath $taskInstall).LinkType) { throw '安装目录检查失败，未执行删除。' }
    Remove-Item -LiteralPath $taskResolved -Recurse -Force
}
Write-Output '轻剪同步已卸载，原小米电脑管家保留。'
