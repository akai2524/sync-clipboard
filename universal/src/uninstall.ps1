$ErrorActionPreference = 'Stop'
$taskRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
if ([IO.Path]::GetFileName($taskRoot) -ne 'LightClipUniversal' -or (Get-Item -LiteralPath $taskRoot).LinkType) { throw '安装目录检查失败，未删除文件。' }
$taskExe = Join-Path $taskRoot 'MiPcContinuity.exe'
if (Test-Path -LiteralPath $taskExe) {
    $taskSignal = Start-Process -FilePath $taskExe -ArgumentList '--stop' -WindowStyle Hidden -PassThru
    $taskSignal.WaitForExit(5000) | Out-Null
    $taskUntil = (Get-Date).AddSeconds(15)
    do {
        $taskRunning = @(Get-Process MiPcContinuity -ErrorAction SilentlyContinue | Where-Object { try { $_.Path -eq $taskExe } catch { $false } })
        if ($taskRunning.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $taskUntil)
    if ($taskRunning.Count -gt 0) { throw '轻剪仍在运行，未删除文件。' }
}
$taskRunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$taskRun = (Get-ItemProperty -LiteralPath $taskRunKey -ErrorAction SilentlyContinue).LightClipUniversal
if ($taskRun -eq ('"' + $taskExe + '" --autostart')) { Remove-ItemProperty -LiteralPath $taskRunKey -Name LightClipUniversal }
$taskShortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) '轻剪同步通用测试版.lnk'
if (Test-Path -LiteralPath $taskShortcut) {
    $taskLink = (New-Object -ComObject WScript.Shell).CreateShortcut($taskShortcut)
    if ($taskLink.TargetPath -eq $taskExe) { Remove-Item -LiteralPath $taskShortcut }
}
Write-Output '轻剪测试版已退出，自启动项和快捷方式已移除。请关闭此窗口后手动删除以下文件夹：'
Write-Output $taskRoot
Write-Output '为避免影响其他软件，小米共享后台服务不会自动卸载。'
Read-Host '按回车关闭'
