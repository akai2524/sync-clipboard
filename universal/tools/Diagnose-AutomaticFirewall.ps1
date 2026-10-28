param([string]$TargetPath, [switch]$SelfTest)

$ErrorActionPreference = 'Stop'
$taskSelfTest = $SelfTest
. (Join-Path $PSScriptRoot 'Configure-LightClipFirewall.ps1') -LibraryOnly

function Test-SameIpv4Subnet([string]$Remote, [string]$Local, [int]$Prefix) {
    if ($Prefix -lt 1 -or $Prefix -gt 32) { return $false }
    $remoteIp = $null; $localIp = $null
    if (-not [Net.IPAddress]::TryParse($Remote, [ref]$remoteIp) -or
        -not [Net.IPAddress]::TryParse($Local, [ref]$localIp) -or
        $remoteIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork -or
        $localIp.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { return $false }
    $remoteBytes = $remoteIp.GetAddressBytes(); $localBytes = $localIp.GetAddressBytes()
    for ($i = 0; $i -lt 4; $i++) {
        $bits = [Math]::Min(8, [Math]::Max(0, $Prefix - ($i * 8)))
        $mask = if ($bits -eq 0) { 0 } else { (255 -shl (8 - $bits)) -band 255 }
        if (($remoteBytes[$i] -band $mask) -ne ($localBytes[$i] -band $mask)) { return $false }
    }
    return $true
}

if ($taskSelfTest) {
    if (-not (Test-SameIpv4Subnet '192.168.1.42' '192.168.1.2' 24) -or
        (Test-SameIpv4Subnet '192.168.2.42' '192.168.1.2' 24) -or
        -not (Test-SameIpv4Subnet '10.1.128.1' '10.1.255.2' 17) -or
        (Test-SameIpv4Subnet '10.1.127.1' '10.1.128.2' 17) -or
        (Test-SameIpv4Subnet '192.168.1.1' '192.168.1.2' 0) -or
        (Test-SameIpv4Subnet '::1' '192.168.1.2' 24)) { throw '子网判断自检失败。' }
    Write-Output 'IPv4 子网判断自检通过；未更改任何设置。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $taskArguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        if ($TargetPath) { $taskArguments += ' -TargetPath "' + $TargetPath + '"' }
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $taskArguments -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host '未获得管理员授权；未更改任何设置。'; Read-Host '按回车关闭' | Out-Null; exit 1 }
}

$exitCode = 0
try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not $TargetPath) {
        $run = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).LightClipUniversal
        if ($run -match '^"([^"]*\\MiPcContinuity\.exe)"(?:\s|$)') {
            $candidate = Split-Path -Parent $Matches[1]
            if (Test-Path -LiteralPath (Join-Path $candidate 'MiPcContinuity.dll') -PathType Leaf) { $TargetPath = $candidate }
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
    if (-not (Test-Path -LiteralPath (Join-Path $root 'MiPcContinuity.dll') -PathType Leaf)) { throw '安装目录检查失败。' }
    $programs = @(Get-ProgramPaths $root)
    $manual = @(Get-OwnedRules (Get-RuleGroup $root) $programs)
    $automatic = @(Get-OwnedRules (Get-RuleGroup $root $true) $programs 'LightClipUniversal local subnet rule')
    $manualEnabled = @($manual | Where-Object { $_.Enabled -eq 'True' }).Count
    $autoEnabled = @($automatic | Where-Object { $_.Enabled -eq 'True' -and $_.Direction -eq 'Inbound' -and $_.Action -eq 'Allow' }).Count
    Write-Host ('手机专属规则：' + $manual.Count + ' 条，启用 ' + $manualEnabled + ' 条')
    Write-Host ('自动网络规则：' + $automatic.Count + ' 条，启用入站允许 ' + $autoEnabled + ' 条')
    $matchingAddress = 0; $interfaces = @()
    foreach ($rule in $automatic) {
        $address = @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)
        $filter = @($rule | Get-NetFirewallInterfaceFilter -ErrorAction Stop)
        if ($address.Count -eq 1 -and @($address[0].RemoteAddress).Count -eq 1 -and $address[0].RemoteAddress -eq 'LocalSubnet4') { $matchingAddress++ }
        if ($filter.Count -eq 1) { $interfaces += @($filter[0].InterfaceAlias) }
    }
    Write-Host ('自动规则中使用本地 IPv4 子网的数量：' + $matchingAddress)
    $phoneAddresses = @(@(
        foreach ($rule in $manual) {
            foreach ($item in @($rule | Get-NetFirewallAddressFilter -ErrorAction Stop)) {
                foreach ($value in @($item.RemoteAddress)) {
                    $candidateAddress = [string]$value
                    if ($candidateAddress -match '^(.+)/32$') { $candidateAddress = $Matches[1] }
                    $ip = $null
                    if ([Net.IPAddress]::TryParse($candidateAddress, [ref]$ip) -and $ip.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork) { $ip.ToString() }
                }
            }
        }
    ) | Select-Object -Unique)
    Write-Host ('可用于比对的旧规则 IPv4 数量：' + @($phoneAddresses).Count)
    $physical = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.ifIndex -gt 0 })
    Write-Host ('现有物理网卡数量：' + $physical.Count)
    if (@($phoneAddresses).Count -eq 1) {
        $physicalIndexes = @($physical | ForEach-Object { $_.ifIndex })
        $local = @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction Stop | Where-Object { $_.InterfaceIndex -in $physicalIndexes })
        if ($local.Count -eq 0) { Write-Host '旧规则地址与物理网卡子网匹配：无法判断' }
        else {
            $match = @($local | Where-Object { Test-SameIpv4Subnet $phoneAddresses[0] $_.IPAddress $_.PrefixLength }).Count -gt 0
            Write-Host ('旧规则地址与物理网卡子网匹配：' + $(if ($match) { '是' } else { '否' }))
        }
        try {
            $routeIndexes = @(Find-NetRoute -RemoteIPAddress $phoneAddresses[0] -ErrorAction Stop | ForEach-Object { $_.InterfaceIndex } | Where-Object { $_ } | Select-Object -Unique)
            $routePhysical = @($physical | Where-Object { $_.ifIndex -in $routeIndexes })
            Write-Host ('到旧规则地址的路由为物理网卡：' + $(if ($routePhysical.Count -gt 0) { '是' } else { '否' }))
            $covered = $false
            foreach ($adapter in $routePhysical) { foreach ($pattern in $interfaces) { if ($adapter.Name -like $pattern) { $covered = $true } } }
            Write-Host ('自动规则包含该路由网卡：' + $(if ($covered) { '是' } else { '否' }))
        } catch { Write-Host '旧规则地址的路由或网卡范围：无法判断' }
    } else { Write-Host '缺少唯一的旧规则地址，无法比较子网和路由。' }
    Write-Host '以上结果不显示 IP 或原始日志；此工具未更改任何设置。'
} catch {
    $exitCode = 1
    Write-Host '检查未完成：无法读取所需的安装目录、规则或网卡信息；未更改任何设置。'
}
Read-Host '按回车关闭' | Out-Null
exit $exitCode
