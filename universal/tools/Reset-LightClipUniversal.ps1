param(
    [ValidateSet('User','Elevated')][string]$Phase = 'User',
    [string]$TargetPath,
    [string]$UserSid,
    [string]$DesktopPath,
    [switch]$PreserveData,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$taskSelfTest = $SelfTest
. (Join-Path $PSScriptRoot 'Configure-LightClipFirewall.ps1') -LibraryOnly
. (Join-Path $PSScriptRoot 'LightClipServiceSecurity.ps1')

function Get-ServiceExecutable([string]$CommandLine) {
    if (-not $CommandLine) { return '' }
    $path = [Environment]::ExpandEnvironmentVariables($CommandLine)
    $match = [regex]::Match($path, '^\s*(?:"([^"]+\.exe)"|(.+?\.exe))(?:\s|$)', 'IgnoreCase')
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

function Test-RootName([string]$Path) {
    if (-not $Path -or $Path -notmatch '^[A-Za-z]:\\') { return $false }
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $name = [IO.Path]::GetFileName($full)
    if ([String]::Equals($name, 'LightClipUniversal', [StringComparison]::OrdinalIgnoreCase)) { return $true }
    if ($name -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$') { return $true }
    return $false
}

function Assert-NoReparse([string]$Path) {
    $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '安装目录中存在链接或重解析点，未删除文件。' }
    if ($item.PSIsContainer) {
        foreach ($child in @(Get-ChildItem -LiteralPath $Path -Force -ErrorAction Stop)) { Assert-NoReparse $child.FullName }
    }
}

function Remove-CleanupDirectory([string]$Path) {
    if (-not (Test-Path -LiteralPath $Path)) { return }
    Assert-NoReparse $Path
    for ($attempt = 1; $attempt -le 10; $attempt++) {
        if (-not (Test-Path -LiteralPath $Path)) { return }
        try {
            Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Attributes -band [IO.FileAttributes]::ReadOnly) {
                    $_.Attributes = $_.Attributes -bxor [IO.FileAttributes]::ReadOnly
                }
            }
            Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction Stop
            if (-not (Test-Path -LiteralPath $Path)) { return }
            throw '删除后目录仍然存在。'
        } catch {
            if (-not (Test-Path -LiteralPath $Path)) { return }
            if ($attempt -eq 10) { throw ('剩余目录未能删除：' + $Path + '；原因：' + $_.Exception.Message) }
            Start-Sleep -Milliseconds (150 * $attempt)
        }
    }
}

function Assert-Root([string]$Path) {
    if (-not (Test-RootName $Path)) { throw ('安装目录名称或路径不符合轻剪通用版，未执行清理。收到的路径：' + $Path + '。请选择安装时创建的 LightClipUniversal 文件夹。') }
    $root = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $item = Get-Item -LiteralPath $root -Force -ErrorAction Stop
    if (-not $item.PSIsContainer -or -not [String]::Equals($item.FullName.TrimEnd('\'), $root, [StringComparison]::OrdinalIgnoreCase)) { throw '无法确认安装目录，未执行清理。' }
    $ancestor = $root
    while ($ancestor) {
        $part = Get-Item -LiteralPath $ancestor -Force -ErrorAction Stop
        if (($part.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '安装路径存在链接或重解析点，未执行清理。' }
        $ancestor = Split-Path -Parent $ancestor
    }
    $isCleanupFolder = [IO.Path]::GetFileName($root) -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$'
    if (-not $isCleanupFolder) {
        foreach ($name in @('MiPcContinuity.dll','lightclip.ico','uninstall.ps1')) {
            if (-not (Test-Path -LiteralPath (Join-Path $root $name) -PathType Leaf)) { throw ('无法确认旧版轻剪：缺少 ' + $name) }
        }
        [void]@(Get-Programs $root)
    }
    Assert-NoReparse $root
    return $root
}

function Get-TemporaryRules([string[]]$Programs) {
    foreach ($rule in @(Get-NetFirewallRule -Name 'LightClipTest-*' -ErrorAction SilentlyContinue)) {
        if ($rule.Name -notmatch '^LightClipTest-[0-9a-f]{32}-[0-5]$' -or $rule.DisplayName -ne 'LightClip temporary image test') { continue }
        $filters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
        if ($filters.Count -eq 1 -and $Programs -contains $filters[0].Program) { $rule }
    }
}

function Find-InstallRoots {
    $candidates = [Collections.Generic.List[string]]::new()
    $run = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).LightClipUniversal
    if ($run -match '^"([^"]*\\MiPcContinuity\.exe)"(?:\s+--autostart)?$') { $candidates.Add((Split-Path -Parent $Matches[1])) }
    $uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\LightClipUniversal'
    $loc = (Get-ItemProperty -LiteralPath $uninstallKey -ErrorAction SilentlyContinue).InstallLocation
    if ($loc -and (Test-Path -LiteralPath $loc)) { $candidates.Add($loc) }
    foreach ($shortcutName in @('轻剪同步.lnk','轻剪同步通用测试版.lnk')) {
        $shortcut = Join-Path ([Environment]::GetFolderPath('DesktopDirectory')) $shortcutName
        if (Test-Path -LiteralPath $shortcut -PathType Leaf) {
            $target = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut).TargetPath
            if ($target -match '\\MiPcContinuity\.exe$') { $candidates.Add((Split-Path -Parent $target)) }
        }
    }
    foreach ($name in @('MiPcContinuityService','micont_service')) {
        $detail = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction SilentlyContinue
        if ($detail) {
            $exe = Get-ServiceExecutable $detail.PathName
            if ($name -eq 'MiPcContinuityService' -and $exe -match '\\x86\\MiPcContinuityService\.exe$') { $candidates.Add((Split-Path -Parent (Split-Path -Parent $exe))) }
            elseif ($name -eq 'micont_service' -and $exe -match '\\micont_service\.exe$') { $candidates.Add((Split-Path -Parent $exe)) }
        }
    }
    foreach ($drive in [IO.DriveInfo]::GetDrives() | Where-Object { $_.DriveType -eq [IO.DriveType]::Fixed -and $_.IsReady }) {
        $rootPath = $drive.RootDirectory.FullName
        foreach ($sub in @('Apps\LightClipUniversal','LightClipUniversal')) {
            $p = Join-Path $rootPath $sub
            if (Test-Path -LiteralPath (Join-Path $p 'MiPcContinuity.dll') -PathType Leaf) { $candidates.Add($p) }
        }
        try {
            Get-ChildItem -LiteralPath $rootPath -Directory -Filter 'LightClipUniversal-cleanup-*' -ErrorAction SilentlyContinue | ForEach-Object {
                if ($_.Name -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$') { $candidates.Add($_.FullName) }
            }
        } catch { }
    }
    $localApp = Join-Path $env:LOCALAPPDATA 'LightClipUniversal'
    if (Test-Path -LiteralPath (Join-Path $localApp 'MiPcContinuity.dll') -PathType Leaf) { $candidates.Add($localApp) }
    return @($candidates | Where-Object { Test-RootName $_ } | ForEach-Object { [IO.Path]::GetFullPath($_).TrimEnd('\') } | Select-Object -Unique)
}

function Assert-NotXiaomiPc {
    $miRoot = Join-Path $env:ProgramFiles 'MI'
    $run = Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue
    if ((Get-Process -Name 'SyncClipboardLite' -ErrorAction SilentlyContinue) -or $run.SyncClipboardLite -or
        (Test-Path -LiteralPath (Join-Path $miRoot 'XiaomiPCManager')) -or (Test-Path -LiteralPath (Join-Path $miRoot 'PcContinuity')) -or
        (Test-Path -LiteralPath 'D:\Apps\LightClip\SyncClipboardLite.exe')) {
        throw '此电脑检测到原小米电脑版或电脑管家，已停止；请只在非小米测试电脑上运行。'
    }
}

if ($taskSelfTest) {
    if (-not (Test-RootName 'D:\Apps\LightClipUniversal') -or (Test-RootName 'D:\Apps\LightClip') -or (Test-RootName 'D:\')) { throw '安装目录识别自检失败。' }
    if (-not (Test-RootName 'D:\LightClipUniversal-cleanup-11111111222233334444555566667777')) { throw '清理目录识别自检失败。' }
    if ((Get-ServiceExecutable '"D:\Apps\LightClipUniversal\micont_service.exe" /service --model=0') -ne 'D:\Apps\LightClipUniversal\micont_service.exe' -or
        (Get-ServiceExecutable 'D:\Apps\LightClipUniversal\x86\MiPcContinuityService.exe /service') -ne 'D:\Apps\LightClipUniversal\x86\MiPcContinuityService.exe') { throw '服务路径判断自检失败。' }
    if ((Get-RuleGroup 'D:\Apps\LightClipUniversal') -eq (Get-RuleGroup 'D:\Apps\LightClipUniversal' $true)) { throw '网络规则分组自检失败。' }
    Write-Output '清理归属判断自检通过；未更改服务、防火墙或文件。'
    exit 0
}

$exitCode = 0
try {
    Add-Type -AssemblyName System.Windows.Forms
    Assert-NotXiaomiPc
    if ($Phase -eq 'User') {
        $roots = @(if ($TargetPath) { $TargetPath } else { Find-InstallRoots })
        if ($roots.Count -eq 0) {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = '请选择包含 MiPcContinuity.exe 的 LightClipUniversal 安装文件夹，而不是上一级文件夹'; $dialog.ShowNewFolderButton = $false
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '没有选择旧版安装目录，未执行清理。' }
            $roots = @($dialog.SelectedPath)
        }
        if ($roots.Count -ne 1) { throw '发现多个可能的旧版目录，无法自动确定，未执行清理。' }
        $root = Assert-Root $roots[0]
        $userSid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
        $desktopPath = [Environment]::GetFolderPath('DesktopDirectory')
        $dataNotice = if ($PreserveData) { '旧版轻剪的数据和缓存会备份到安装目录旁边。' } else { '旧版轻剪的数据和缓存会随旧版一起删除。' }
        $text = "将清理这个旧版轻剪：`n$root`n`n移除属于该目录的防火墙规则、后台服务、自启动项、快捷方式和程序文件。其他位置的小米服务与共享数据不会删除。`n`n$dataNotice`n`n是否继续？"
        if ([Windows.Forms.MessageBox]::Show($text, '轻剪旧版一键清理', 'OKCancel', 'Warning') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未执行清理。' }
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Phase Elevated -TargetPath "' + $root + '" -UserSid "' + $userSid + '" -DesktopPath "' + $desktopPath + '"'
        if ($PreserveData) { $arguments += ' -PreserveData' }
        $powershell = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $child = Start-Process -FilePath $powershell -Verb RunAs -ArgumentList $arguments -PassThru -Wait
        exit $child.ExitCode
    }

    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '未获得管理员权限，未执行清理。' }
    try { $validatedSid = New-Object Security.Principal.SecurityIdentifier($UserSid) } catch { throw '无法确认原登录用户，未执行清理。' }
    if (-not $validatedSid -or -not $DesktopPath) { throw '无法确认原登录用户，未执行清理。' }
    $root = Assert-Root $TargetPath
    $runKey = 'Registry::HKEY_USERS\' + $UserSid + '\Software\Microsoft\Windows\CurrentVersion\Run'
    if (-not (Test-Path -LiteralPath ('Registry::HKEY_USERS\' + $UserSid))) { throw '原登录用户的注册表未加载，未执行清理。' }
    $programs = @(Get-ProgramPaths $root)
    $rules = @(Get-OwnedRules (Get-RuleGroup $root) $programs) + @(Get-OwnedRules (Get-RuleGroup $root $true) $programs 'LightClipUniversal local subnet rule') + @(Get-TemporaryRules $programs)
    $serviceItems = @(
        @{ Name='MiPcContinuityService'; Exe=(Join-Path $root 'x86\MiPcContinuityService.exe') },
        @{ Name='micont_service'; Exe=(Join-Path $root 'micont_service.exe') }
    )
    $ownedServices = @(); $otherServices = @()
    foreach ($item in $serviceItems) {
        $detail = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $item.Name + "'") -ErrorAction Stop
        if (-not $detail) { continue }
        if ([String]::Equals((Get-ServiceExecutable $detail.PathName), $item.Exe, [StringComparison]::OrdinalIgnoreCase)) { $ownedServices += $item }
        else { $otherServices += $item.Name }
    }
    $securitySnapshot = Join-Path $root 'data\LightClipUniversal-reset-service.original-dacl'
    $protectedService = @($ownedServices | Where-Object { $_.Name -eq 'MiPcContinuityService' })
    if (Test-Path -LiteralPath $securitySnapshot -PathType Leaf) {
        if ($protectedService.Count -ne 1) { throw '发现未完成的权限恢复记录，但无法确认其服务归属；未继续清理。' }
        $saved = [IO.File]::ReadAllBytes($securitySnapshot)
        if ($saved.Length -eq 0 -or $saved.Length -gt 65536) { throw '服务权限恢复记录无效，未继续清理。' }
        [void](Get-DaclText $saved)
        [LightClipServiceSecurity]::WriteDacl('MiPcContinuityService', $saved)
        if ((Get-DaclText ([LightClipServiceSecurity]::ReadDacl('MiPcContinuityService'))) -ne (Get-DaclText $saved)) { throw '之前的服务权限恢复未通过检查，未继续清理。' }
        Remove-Item -LiteralPath $securitySnapshot -Force -ErrorAction Stop
    }
    $exePath = Join-Path $root 'MiPcContinuity.exe'
    $stop = Start-Process -FilePath $exePath -ArgumentList '--stop' -WindowStyle Hidden -PassThru
    $stop.WaitForExit(5000) | Out-Null
    $deadline = (Get-Date).AddSeconds(15)
    do {
        $running = @(Get-Process -Name MiPcContinuity -ErrorAction SilentlyContinue | Where-Object { try { [String]::Equals($_.Path, $exePath, [StringComparison]::OrdinalIgnoreCase) } catch { $false } })
        if ($running.Count -eq 0) { break }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $deadline)
    if ($running.Count -gt 0) { throw '旧版轻剪未能退出，未删除规则、服务或文件。' }
    $backup = $null
    $data = Join-Path $root 'data'
    if ($PreserveData -and (Test-Path -LiteralPath $data -PathType Container)) {
        $parent = Split-Path -Parent $root
        $backup = Join-Path $parent ('LightClipUniversal-data-backup-' + (Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [Guid]::NewGuid().ToString('N').Substring(0,8))
        if (Test-Path -LiteralPath $backup) { throw '备份目标已存在，未执行清理。' }
        Copy-Item -LiteralPath $data -Destination $backup -Recurse -ErrorAction Stop
    }
    foreach ($item in $ownedServices) {
        $service = Get-Service -Name $item.Name -ErrorAction Stop
        if ($service.Status -ne 'Stopped') {
            try {
                Stop-Service -Name $item.Name -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
            } catch {
                if ($item.Name -ne 'MiPcContinuityService' -or [LightClipServiceSecurity]::CheckStop($item.Name) -ne 5) { throw }
                $original = [LightClipServiceSecurity]::ReadDacl($item.Name)
                $temporary = Get-StopEnabledDescriptor $original ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
                [IO.Directory]::CreateDirectory((Split-Path -Parent $securitySnapshot)) | Out-Null
                $set = { param([byte[]]$value) [LightClipServiceSecurity]::WriteDacl($item.Name, $value) }
                $read = { [LightClipServiceSecurity]::ReadDacl($item.Name) }
                $action = {
                    if ([LightClipServiceSecurity]::CheckStop($item.Name) -ne 0) { throw '临时停止权限未生效。' }
                    Stop-Service -Name $item.Name -ErrorAction Stop
                    $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Stopped, [TimeSpan]::FromSeconds(20))
                }
                Write-Host '正在临时调整旧版服务的停止权限，完成后立即恢复。'
                Invoke-TemporaryServiceDacl $securitySnapshot $original $temporary $set $read $action
            }
        }
        $service.Dispose()
        & (Join-Path $env:WINDIR 'System32\sc.exe') delete $item.Name | Out-Null
        if ($LASTEXITCODE -ne 0) { throw ($item.Name + ' 未能注销，清理未完成。') }
    }

    # 彻底关闭严格位于当前安装目录下的所有关联子进程（如 MiUserLogon.exe, SSO_Cef_Sub.exe 等，解除 dll 句柄占用）
    $rootPrefix = $root + '\'
    $procDeadline = (Get-Date).AddSeconds(10)
    do {
        $ownedProcs = @(Get-Process -ErrorAction SilentlyContinue | Where-Object {
            try {
                $_.Path -and [IO.Path]::GetFullPath($_.Path).StartsWith($rootPrefix, [StringComparison]::OrdinalIgnoreCase)
            } catch { $false }
        })
        if ($ownedProcs.Count -eq 0) { break }
        foreach ($p in $ownedProcs) {
            try { Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue } catch { }
        }
        Start-Sleep -Milliseconds 250
    } while ((Get-Date) -lt $procDeadline)

    foreach ($rule in $rules) { Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop }
    $run = (Get-ItemProperty -LiteralPath $runKey -ErrorAction SilentlyContinue).LightClipUniversal
    if ([String]::Equals($run, ('"' + $exePath + '" --autostart'), [StringComparison]::OrdinalIgnoreCase)) { Remove-ItemProperty -LiteralPath $runKey -Name LightClipUniversal -ErrorAction Stop }
    foreach ($shortcutName in @('轻剪同步.lnk','轻剪同步通用测试版.lnk')) {
        $shortcut = Join-Path $DesktopPath $shortcutName
        if (Test-Path -LiteralPath $shortcut -PathType Leaf) {
            $link = (New-Object -ComObject WScript.Shell).CreateShortcut($shortcut)
            if ([String]::Equals($link.TargetPath, $exePath, [StringComparison]::OrdinalIgnoreCase)) { Remove-Item -LiteralPath $shortcut -Force -ErrorAction Stop }
        }
    }

    # 清理注册表中的 Windows 标准卸载项
    $uninstallReg = 'Registry::HKEY_USERS\' + $UserSid + '\Software\Microsoft\Windows\CurrentVersion\Uninstall\LightClipUniversal'
    if (Test-Path -LiteralPath $uninstallReg) { Remove-Item -LiteralPath $uninstallReg -Recurse -Force -ErrorAction SilentlyContinue }
    $curUninstallReg = 'Registry::HKEY_CURRENT_USER\Software\Microsoft\Windows\CurrentVersion\Uninstall\LightClipUniversal'
    if (Test-Path -LiteralPath $curUninstallReg) { Remove-Item -LiteralPath $curUninstallReg -Recurse -Force -ErrorAction SilentlyContinue }

    [void](Assert-Root $root)
    $isAlreadyCleanup = [IO.Path]::GetFileName($root) -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$'
    $moved = $root
    if (-not $isAlreadyCleanup) {
        $parent = [IO.Path]::GetFullPath((Split-Path -Parent $root))
        $quarantine = [IO.Path]::GetFullPath((Join-Path $parent ('LightClipUniversal-cleanup-' + [Guid]::NewGuid().ToString('N'))))
        if (-not [String]::Equals([IO.Path]::GetDirectoryName($quarantine).TrimEnd('\'), $parent.TrimEnd('\'), [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $quarantine)) { throw '临时清理目录校验失败。' }
        Move-Item -LiteralPath $root -Destination $quarantine -ErrorAction Stop
        $moved = (Get-Item -LiteralPath $quarantine -Force -ErrorAction Stop).FullName.TrimEnd('\')
        if (-not [String]::Equals($moved, $quarantine, [StringComparison]::OrdinalIgnoreCase) -or -not [IO.Path]::GetFileName($moved).StartsWith('LightClipUniversal-cleanup-', [StringComparison]::Ordinal)) { throw '临时清理目录校验失败，旧版文件已保留。' }
    }
    Assert-NoReparse $moved
    Remove-CleanupDirectory $moved
    Write-Host ('旧版轻剪清理完成。已移除规则：' + $rules.Count + ' 条；已注销本目录服务：' + $ownedServices.Count + ' 项。')
    if ($backup) { Write-Host ('旧版数据备份：' + $backup) }
    if ($otherServices.Count -gt 0) { Write-Host ('以下同名服务属于其他安装位置，已保留：' + ($otherServices -join ', ')) }
    Write-Host '小米共享缓存和其他软件的数据未删除。现在可以运行新版安装包。'
} catch {
    $exitCode = 1
    Write-Host ('清理未完成：' + $_.Exception.Message)
    Write-Host '请保留窗口中的提示；未确认归属的项目不会被清理。'
}
Read-Host '按回车关闭' | Out-Null
exit $exitCode