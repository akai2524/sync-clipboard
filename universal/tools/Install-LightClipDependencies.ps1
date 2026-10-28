param([string]$InstallPath, [string]$ResultPath, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'

function Invoke-SetupSteps([string]$Root, [scriptblock]$Runner) {
    & $Runner '小米互联服务' (Join-Path $Root 'tools\Repair-LightClipServices.ps1') @('-InstallPath', $Root, '-Unattended', '-NoPause')
    & $Runner '自动网络规则' (Join-Path $Root 'tools\Configure-LightClipFirewall.ps1') @('-InstallPath', $Root, '-Mode', 'Automatic', '-Unattended', '-NoPause')
}

if ($SelfTest) {
    $calls = [Collections.Generic.List[object]]::new()
    $record = { param($name, $script, $stepArgs) $calls.Add([PSCustomObject]@{ Name=$name; Script=$script; Args=$stepArgs }) }
    Invoke-SetupSteps 'D:\Apps\LightClipUniversal' $record
    if ($calls.Count -ne 2 -or $calls[0].Name -ne '小米互联服务' -or $calls[1].Name -ne '自动网络规则' -or
        $calls[0].Args -notcontains '-Unattended' -or $calls[1].Args -notcontains '-Unattended' -or
        $calls[1].Args -notcontains 'Automatic' -or $calls[0].Args -notcontains '-NoPause' -or $calls[1].Args -notcontains '-NoPause') { throw '自动安装步骤自检失败。' }
    $attempts = [Collections.Generic.List[string]]::new()
    $fail = { param($name, $script, $stepArgs) $attempts.Add($name); throw '模拟服务失败' }
    $failed = $false; try { Invoke-SetupSteps 'D:\Apps\LightClipUniversal' $fail } catch { $failed = $true }
    if (-not $failed -or $attempts.Count -ne 1) { throw '自动安装失败处理自检失败。' }
    Write-Output '自动安装步骤与失败处理自检通过；未更改服务或防火墙。'
    exit 0
}

$result = '安装配置未完成。'
$exitCode = 1
try {
    if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '没有管理员权限。' }
    if (-not $InstallPath -or -not $ResultPath) { throw '安装路径或结果路径缺失。' }
    $root = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    $resultFile = [IO.Path]::GetFullPath($ResultPath)
    $dataDir = [IO.Path]::GetFullPath((Join-Path $root 'data')).TrimEnd('\')
    if (-not [String]::Equals([IO.Path]::GetDirectoryName($resultFile), $dataDir, [StringComparison]::OrdinalIgnoreCase) -or
        [IO.Path]::GetFileName($resultFile) -notmatch '^setup-result-[0-9a-f]{32}\.txt$') { throw '结果路径校验失败。' }
    if (-not (Test-Path -LiteralPath (Join-Path $root 'MiPcContinuity.dll') -PathType Leaf)) { throw '安装组件不完整。' }
    $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $runner = {
        param($name, $script, $stepArgs)
        if (-not (Test-Path -LiteralPath $script -PathType Leaf)) { throw ($name + '工具缺失。') }
        $output = @(& $psExe -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $script @stepArgs 2>&1)
        if ($LASTEXITCODE -ne 0) {
            $detail = @($output | ForEach-Object { $_.ToString() } | Select-Object -Last 5) -join [Environment]::NewLine
            throw ($name + '设置失败。' + [Environment]::NewLine + $detail)
        }
    }
    Invoke-SetupSteps $root $runner
    $result = '小米互联服务和自动网络规则已配置。'
    $exitCode = 0
} catch { $result = $_.Exception.Message }
try {
    if ($resultFile -and $dataDir -and [String]::Equals([IO.Path]::GetDirectoryName($resultFile), $dataDir, [StringComparison]::OrdinalIgnoreCase) -and
        [IO.Path]::GetFileName($resultFile) -match '^setup-result-[0-9a-f]{32}\.txt$') {
        [IO.File]::WriteAllText($resultFile, $result, [Text.Encoding]::UTF8)
    }
} catch { $exitCode = 1 }
exit $exitCode
