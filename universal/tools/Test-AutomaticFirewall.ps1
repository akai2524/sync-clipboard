param(
    [ValidateSet('Test','Restore')][string]$Action = 'Test',
    [string]$TargetPath,
    [switch]$SelfTest
)

$ErrorActionPreference = 'Stop'
$taskSelfTest = $SelfTest
. (Join-Path $PSScriptRoot 'Configure-LightClipFirewall.ps1') -LibraryOnly

function Restore-MarkedRules([string[]]$Names, [string[]]$Allowed, [scriptblock]$Enable) {
    foreach ($name in $Names) { if ($name -notin $Allowed) { throw '恢复记录包含不属于本安装目录的规则，未执行恢复。' } }
    foreach ($name in $Names) { & $Enable $name }
}

function Invoke-IsolatedTest([string[]]$Names, [scriptblock]$Disable, [scriptblock]$RunTest, [scriptblock]$Restore) {
    try {
        foreach ($name in $Names) { & $Disable $name }
        & $RunTest
    } finally { & $Restore }
}

if ($taskSelfTest) {
    $enabled = [Collections.Generic.List[string]]::new()
    $fake = { param($name) $enabled.Add($name) }
    Restore-MarkedRules @('a','b') @('a','b','c') $fake
    if ($enabled.Count -ne 2 -or $enabled[0] -ne 'a' -or $enabled[1] -ne 'b') { throw '恢复测试失败。' }
    $rejected = $false
    try { Restore-MarkedRules @('a','other') @('a','b') $fake } catch { $rejected = $true }
    if (-not $rejected -or $enabled.Count -ne 2) { throw '非本程序规则未被拒绝。' }
    $state = @{a=$true; b=$true}; $disable = { param($name) $state[$name] = $false }
    $restore = { $state['a']=$true; $state['b']=$true }; $fail = { throw '模拟测试异常' }
    $rejected = $false; try { Invoke-IsolatedTest @('a','b') $disable $fail $restore } catch { $rejected = $true }
    if (-not $rejected -or -not $state['a'] -or -not $state['b']) { throw '异常恢复测试失败。' }
    Write-Output '规则恢复及归属校验通过；未修改防火墙。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Action ' + $Action
        if ($TargetPath) { $taskArguments += ' -TargetPath "' + $TargetPath + '"' }
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $taskArguments -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host '未获得管理员授权，未修改防火墙。'; Read-Host '按回车关闭' | Out-Null; exit 1 }
}

$exitCode = 0
$marker = $null
$manual = @()
try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not $TargetPath) {
        $parent = Split-Path -Parent $PSScriptRoot
        if (Test-Path -LiteralPath (Join-Path $parent 'MiPcContinuity.dll') -PathType Leaf) { $TargetPath = $parent }
        if (-not $TargetPath) {
            $run = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).LightClipUniversal
            if ($run -match '^"([^"]*\\MiPcContinuity\.exe)"(?:\s|$)') {
                $candidate = Split-Path -Parent $Matches[1]
                if (Test-Path -LiteralPath (Join-Path $candidate 'MiPcContinuity.dll') -PathType Leaf) { $TargetPath = $candidate }
            }
        }
        if (-not $TargetPath) {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = '请选择轻剪通用版安装目录'; $dialog.ShowNewFolderButton = $false
            if (Test-Path -LiteralPath 'D:\Apps\LightClipUniversal') { $dialog.SelectedPath = 'D:\Apps\LightClipUniversal' }
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '未选择安装目录。' }
            $TargetPath = $dialog.SelectedPath
        }
    }
    $root = [IO.Path]::GetFullPath($TargetPath).TrimEnd('\')
    $programs = @(Get-ProgramPaths $root)
    $manual = @(Get-OwnedRules (Get-RuleGroup $root) $programs)
    $marker = Join-Path $root 'data\firewall-test-restore.txt'
    if ($Action -eq 'Restore') {
        if (-not (Test-Path -LiteralPath $marker -PathType Leaf)) { Write-Host '没有需要恢复的测试规则。' }
        else {
            $names = @([IO.File]::ReadAllLines($marker, [Text.Encoding]::UTF8))
            $allowed = @($manual | ForEach-Object { $_.Name })
            $enable = { param($name) Enable-NetFirewallRule -Name $name -ErrorAction Stop | Out-Null }
            Restore-MarkedRules $names $allowed $enable
            Remove-Item -LiteralPath $marker -Force
            Write-Host '测试前启用的手机专属规则已恢复。'
        }
    } else {
        if (Test-Path -LiteralPath $marker) { throw '检测到上一次测试尚未恢复，请先运行 restore-manual-rules.cmd。' }
        [void]@(Get-Programs $root)
        $automatic = @(Get-OwnedRules (Get-RuleGroup $root $true) $programs 'LightClipUniversal local subnet rule')
        if ($automatic.Count -ne 6 -or @($automatic | Where-Object { $_.Enabled -ne 'True' -or $_.Direction -ne 'Inbound' -or $_.Action -ne 'Allow' }).Count -ne 0) { throw '自动规则尚未完整启用，请先运行 configure-auto-firewall.cmd。' }
        foreach ($rule in $automatic) {
            $addressFilter = @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
            $interfaceFilter = @($rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
            if ($addressFilter.Count -ne 1 -or @($addressFilter[0].RemoteAddress).Count -ne 1 -or $addressFilter[0].RemoteAddress -ne 'LocalSubnet4' -or
                $interfaceFilter.Count -ne 1 -or @($interfaceFilter[0].InterfaceAlias).Count -eq 0 -or 'Any' -in @($interfaceFilter[0].InterfaceAlias)) {
                throw '自动规则的网络范围与预期不符，未开始测试。'
            }
        }
        $active = @($manual | Where-Object { $_.Enabled -eq 'True' } | ForEach-Object { $_.Name })
        $consent = [Windows.Forms.MessageBox]::Show('测试会临时关闭本安装目录中原有的手机专属规则，让图片仅通过自动局域网规则传输。完成测试后按回车，程序会恢复之前启用的规则。', '轻剪自动网络测试', 'OKCancel', 'Information')
        if ($consent -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，原有规则未改变。' }
        if ($active.Count -gt 0) {
            [IO.Directory]::CreateDirectory((Split-Path -Parent $marker)) | Out-Null
            $stream = New-Object IO.FileStream($marker, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::Read)
            try {
                $writer = New-Object IO.StreamWriter($stream, [Text.Encoding]::UTF8)
                try { foreach ($name in $active) { $writer.WriteLine($name) } } finally { $writer.Dispose() }
            } finally { $stream.Dispose() }
        }
        $disable = { param($name) Disable-NetFirewallRule -Name $name -ErrorAction Stop | Out-Null }
        $runTest = {
            Write-Host '测试已开始。请在电脑截图，随后在手机便签中粘贴；不用输入手机 IP。'
            Read-Host '完成后回到此窗口按回车，恢复手机专属规则' | Out-Null
        }
        $restore = {
            if ($active.Count -gt 0 -and (Test-Path -LiteralPath $marker -PathType Leaf)) {
                $names = @([IO.File]::ReadAllLines($marker, [Text.Encoding]::UTF8))
                $allowed = @($manual | ForEach-Object { $_.Name })
                $enable = { param($name) Enable-NetFirewallRule -Name $name -ErrorAction Stop | Out-Null }
                Restore-MarkedRules $names $allowed $enable
                Remove-Item -LiteralPath $marker -Force
                Write-Host '测试前启用的手机专属规则已恢复。'
            }
        }
        Invoke-IsolatedTest $active $disable $runTest $restore
    }
} catch {
    $exitCode = 1
    Write-Host ('测试未完成：' + $_.Exception.Message)
    if ($marker -and (Test-Path -LiteralPath $marker -PathType Leaf)) { Write-Host '请运行 restore-manual-rules.cmd 恢复原有规则。' }
}
Read-Host '按回车关闭' | Out-Null
exit $exitCode
