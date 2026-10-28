param(
    [switch]$InspectOnly,
    [string]$InstallPath,
    [switch]$NoPause,
    [switch]$Unattended
)

$ErrorActionPreference = 'Stop'

function Test-OfficialComponents([string]$Root) {
    $items = @(
        (Join-Path $Root 'micont_service.exe'),
        (Join-Path $Root 'x86\MiPcContinuityService.exe')
    )
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'MiPcContinuity.dll') -PathType Leaf)) {
        throw '所选目录不是轻剪通用版安装目录：缺少 MiPcContinuity.dll。'
    }
    foreach ($item in $items) {
        if (-not (Test-Path -LiteralPath $item -PathType Leaf)) { throw ('缺少官方服务文件：' + (Split-Path $item -Leaf)) }
        $signature = Get-AuthenticodeSignature -LiteralPath $item
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN="?Xiaomi Communications Co\., Ltd\."?') {
            throw ('官方签名验证失败：' + (Split-Path $item -Leaf) + '，状态：' + $signature.Status)
        }
    }
}

function Get-ServiceExecutable([string]$CommandLine) {
    $path = [Environment]::ExpandEnvironmentVariables($CommandLine)
    $match = [regex]::Match($path, '^\s*(?:"([^"]+\.exe)"|(.+?\.exe))(?:\s|$)', 'IgnoreCase')
    if (-not $match.Success) { return '' }
    if ($match.Groups[1].Success) { return $match.Groups[1].Value }
    return $match.Groups[2].Value
}

if ($InspectOnly) {
    if (-not $InstallPath) { throw 'InspectOnly 需要指定 InstallPath。' }
    Test-OfficialComponents ([IO.Path]::GetFullPath($InstallPath))
    Write-Output '官方服务文件签名检查通过；未安装或启动服务。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        if ($InstallPath) { $arguments += ' -InstallPath "' + $InstallPath + '"' }
        if ($NoPause) { $arguments += ' -NoPause' }
        if ($Unattended) { $arguments += ' -Unattended' }
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host '未获得管理员授权，未更改服务。'; if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }; exit 1 }
}

$exitCode = 0
try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not $InstallPath) {
        $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
        $dialog.Description = '请选择轻剪通用版安装目录（里面有 MiPcContinuity.dll）'
        $dialog.ShowNewFolderButton = $false
        if (Test-Path -LiteralPath 'D:\Apps\LightClipUniversal') { $dialog.SelectedPath = 'D:\Apps\LightClipUniversal' }
        if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '未选择安装目录。' }
        $InstallPath = $dialog.SelectedPath
    }
    $root = [IO.Path]::GetFullPath($InstallPath)
    Test-OfficialComponents $root
    if (-not $Unattended) {
        $reply = [Windows.Forms.MessageBox]::Show('将使用小米官方组件注册缺失的互联后台服务。其他安装位置的同名服务不会修改；属于本安装目录且未运行的服务会尝试启动。', '轻剪通用版服务修复', 'OKCancel', 'Information')
        if ($reply -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未更改服务。' }
    }

    $services = @(
        @{ Name = 'MiPcContinuityService'; Exe = (Join-Path $root 'x86\MiPcContinuityService.exe'); Args = '/service' },
        @{ Name = 'micont_service'; Exe = (Join-Path $root 'micont_service.exe'); Args = '/service --model=0' }
    )
    foreach ($item in $services) {
        $service = Get-Service -Name $item.Name -ErrorAction SilentlyContinue
        if ($null -ne $service) {
            Write-Host ($item.Name + ' 已存在；当前状态：' + $service.Status)
            $detail = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $item.Name + "'") -ErrorAction Stop
            $existingExe = Get-ServiceExecutable $detail.PathName
            if (-not [String]::Equals($existingExe, $item.Exe, [StringComparison]::OrdinalIgnoreCase)) {
                Write-Host ($item.Name + ' 指向其他安装位置，为避免影响其他软件，没有修改该服务。')
                $exitCode = 1
            } elseif ($service.Status -ne 'Running') {
                Start-Service -Name $item.Name -ErrorAction Stop
                $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
                $service.Refresh()
                Write-Host ($item.Name + ' 当前状态：' + $service.Status)
            }
            continue
        }
        Write-Host ('正在注册 ' + $item.Name + ' ...')
        $process = Start-Process -FilePath $item.Exe -ArgumentList $item.Args -WorkingDirectory (Split-Path $item.Exe -Parent) -PassThru -Wait -NoNewWindow
        $service = Get-Service -Name $item.Name -ErrorAction SilentlyContinue
        if ($null -eq $service) { throw ($item.Name + ' 注册未成功，官方程序退出码：' + $process.ExitCode) }
        $detail = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $item.Name + "'") -ErrorAction Stop
        if (-not [String]::Equals((Get-ServiceExecutable $detail.PathName), $item.Exe, [StringComparison]::OrdinalIgnoreCase)) {
            throw ($item.Name + ' 注册后的路径不是本安装目录，未启动该服务。')
        }
        if ($service.Status -ne 'Running') {
            Start-Service -Name $item.Name
            $service.WaitForStatus([System.ServiceProcess.ServiceControllerStatus]::Running, [TimeSpan]::FromSeconds(15))
            $service.Refresh()
        }
        Write-Host ($item.Name + ' 当前状态：' + $service.Status)
    }
    if ($exitCode -eq 0) { Write-Host '检查完成。请关闭本窗口，退出并重新打开轻剪，再尝试发现手机。' }
    else { Write-Host '至少一个现有服务未运行；为避免影响其他软件，工具没有修改它。' }
} catch {
    $exitCode = 1
    Write-Host ('操作未完成：' + $_.Exception.Message)
}
if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
exit $exitCode
