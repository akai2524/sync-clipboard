param(
    [ValidateSet('Configure','Automatic','Remove','RemoveAutomatic','RemoveAll')][string]$Mode = 'Configure',
    [string]$InstallPath,
    [switch]$InspectOnly,
    [switch]$SelfTest,
    [switch]$NoPause,
    [switch]$LibraryOnly
)

$ErrorActionPreference = 'Stop'

function Get-RuleGroup([string]$Root, [bool]$Automatic = $false) {
    $bytes = [Text.Encoding]::UTF8.GetBytes([IO.Path]::GetFullPath($Root).TrimEnd('\').ToUpperInvariant())
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $hash = [BitConverter]::ToString($sha.ComputeHash($bytes)).Replace('-', '').Substring(0, 20) }
    finally { $sha.Dispose() }
    if ($Automatic) { return 'LightClipUniversalAuto-' + $hash }
    return 'LightClipUniversal-' + $hash
}

function Get-PhoneAddress([string]$Value) {
    $ip = $null
    if ($Value.Trim() -notmatch '^\d{1,3}(\.\d{1,3}){3}$' -or -not [Net.IPAddress]::TryParse($Value.Trim(), [ref]$ip) -or $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw '请输入完整的手机 IPv4 地址。' }
    $a = $ip.GetAddressBytes()
    $private = $a[0] -eq 10 -or ($a[0] -eq 172 -and $a[1] -ge 16 -and $a[1] -le 31) -or ($a[0] -eq 192 -and $a[1] -eq 168) -or ($a[0] -eq 169 -and $a[1] -eq 254)
    if (-not $private -or $a[3] -eq 0 -or $a[3] -eq 255) { throw '请输入手机的局域网 IPv4 地址，不要填写网段或广播地址。' }
    return $ip.ToString()
}

function Get-ProgramPaths([string]$Root) {
    foreach ($name in @('MiPcContinuity.exe', 'micont_service.exe', 'x86\MiPcContinuityService.exe')) {
        [IO.Path]::GetFullPath((Join-Path $Root $name))
    }
}

function Get-Programs([string]$Root) {
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'MiPcContinuity.dll') -PathType Leaf)) { throw '所选目录不是轻剪通用版安装目录。' }
    $programs = @()
    foreach ($path in @(Get-ProgramPaths $Root)) {
        $name = Split-Path $path -Leaf
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('缺少小米组件：' + $name) }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN="?Xiaomi Communications Co\., Ltd\."?') { throw ('小米组件签名验证失败：' + $name) }
        $programs += $path
    }
    return $programs
}

function Get-OwnedRules([string]$Group, [string[]]$Programs, [string]$Description = 'LightClipUniversal phone-specific rule') {
    foreach ($rule in @(Get-NetFirewallRule -Group $Group -ErrorAction SilentlyContinue)) {
        $filters = @($rule | Get-NetFirewallApplicationFilter -ErrorAction Stop)
        if ($rule.Name -notmatch ('^' + [regex]::Escape($Group) + '-[0-9a-f]{32}-[0-5]$') -or
            $rule.Description -ne $Description -or $filters.Count -ne 1 -or
            -not ($Programs -contains $filters[0].Program)) {
            throw '发现无法确认归属的同组规则，未修改这些规则。'
        }
        $rule
    }
}

function Install-PhoneRules([string]$Group, [string[]]$Programs, [string]$Phone, [object[]]$OldRules, [scriptblock]$Create, [scriptblock]$Remove) {
    $created = New-Object 'System.Collections.Generic.List[string]'
    try {
        $tag = [Guid]::NewGuid().ToString('N'); $index = 0
        foreach ($program in $Programs) {
            foreach ($protocol in @('TCP','UDP')) {
                $name = $Group + '-' + $tag + '-' + $index
                & $Create $name $Group $program $protocol $Phone
                $created.Add($name); $index++
            }
        }
    } catch {
        foreach ($name in $created) { try { & $Remove $name } catch { Write-Host ('新规则清理失败：' + $name) } }
        throw
    }
    $oldClean = $true
    foreach ($rule in $OldRules) {
        try { & $Remove $rule.Name }
        catch { $oldClean = $false; Write-Host ('旧规则未能删除：' + $rule.Name) }
    }
    return $oldClean
}

if ($LibraryOnly) { return }

if ($SelfTest) {
    if ((Get-PhoneAddress '192.168.31.42') -ne '192.168.31.42') { throw '地址验证失败。' }
    foreach ($bad in @('192.16831.1','8.8.8.8','192.168.31.255')) {
        $rejected = $false; try { [void](Get-PhoneAddress $bad) } catch { $rejected = $true }
        if (-not $rejected) { throw '非法地址没有被拒绝。' }
    }
    if ((Get-RuleGroup 'D:\Apps\LightClipUniversal') -ne (Get-RuleGroup 'd:\apps\lightclipuniversal\')) { throw '规则分组不一致。' }
    if ((Get-RuleGroup 'D:\Apps\LightClipUniversal') -eq (Get-RuleGroup 'D:\Apps\LightClipUniversal' $true)) { throw '自动规则与原规则未隔离。' }
    $fakeRules = @{'old' = $true}; $fakeAttempt = [Collections.Generic.List[string]]::new()
    $fakeRemove = { param($name) $fakeRules.Remove($name) | Out-Null }
    $fakeFail = { param($name,$group,$program,$protocol,$phone) if ($fakeAttempt.Count -eq 2) { throw '模拟创建失败' }; $fakeRules[$name] = $true; $fakeAttempt.Add($name) }
    $old = @([PSCustomObject]@{ Name = 'old' }); $programs = @('program1','program2','program3')
    $rejected = $false; try { Install-PhoneRules 'test' $programs '192.168.31.42' $old $fakeFail $fakeRemove } catch { $rejected = $true }
    if (-not $rejected -or $fakeRules.Count -ne 1 -or -not $fakeRules.ContainsKey('old')) { throw '失败回滚自检失败。' }
    $fakeCreate = { param($name,$group,$program,$protocol,$phone) $fakeRules[$name] = $true }
    $clean = Install-PhoneRules 'test' $programs '192.168.31.42' $old $fakeCreate $fakeRemove
    if (-not $clean -or $fakeRules.Count -ne 6 -or $fakeRules.ContainsKey('old')) { throw '规则替换自检失败。' }
    $specs = [Collections.Generic.List[object]]::new()
    $fakeAuto = { param($name,$group,$program,$protocol,$address) $specs.Add([PSCustomObject]@{ Program=$program; Protocol=$protocol; Address=$address }) }
    $clean = Install-PhoneRules 'automatic-test' $programs 'LocalSubnet4' @() $fakeAuto $fakeRemove
    if (-not $clean -or $specs.Count -ne 6 -or @($specs | Where-Object { $_.Address -ne 'LocalSubnet4' -or $_.Protocol -notin @('TCP','UDP') -or $_.Program -notin $programs }).Count -ne 0) { throw '自动规则范围自检失败。' }
    Write-Output '地址、规则替换和失败回滚自检通过；未更改防火墙。'
    exit 0
}

if ($InspectOnly) {
    if (-not $InstallPath) { throw 'InspectOnly 需要指定 InstallPath。' }
    if (@(Get-Programs ([IO.Path]::GetFullPath($InstallPath))).Count -ne 3) { throw '组件数量不正确。' }
    Write-Output '小米组件签名检查通过；未更改防火墙。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '" -Mode ' + $Mode
        if ($InstallPath) { $arguments += ' -InstallPath "' + $InstallPath + '"' }
        if ($NoPause) { $arguments += ' -NoPause' }
        $child = Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host '未获得管理员授权，未更改防火墙。'; if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }; exit 1 }
}

$exitCode = 0
try {
    Add-Type -AssemblyName System.Windows.Forms
    if (-not $InstallPath) {
        $parent = Split-Path -Parent $PSScriptRoot
        if (Test-Path -LiteralPath (Join-Path $parent 'MiPcContinuity.dll') -PathType Leaf) { $InstallPath = $parent }
        if (-not $InstallPath) {
            $run = (Get-ItemProperty -LiteralPath 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -ErrorAction SilentlyContinue).LightClipUniversal
            if ($run -match '^"([^"]*\\MiPcContinuity\.exe)"(?:\s|$)') {
                $candidate = Split-Path -Parent $Matches[1]
                if (Test-Path -LiteralPath (Join-Path $candidate 'MiPcContinuity.dll') -PathType Leaf) { $InstallPath = $candidate }
            }
        }
        if (-not $InstallPath) {
            $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
            $dialog.Description = '请选择轻剪通用版安装目录'
            $dialog.ShowNewFolderButton = $false
            if (Test-Path -LiteralPath 'D:\Apps\LightClipUniversal') { $dialog.SelectedPath = 'D:\Apps\LightClipUniversal' }
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '未选择安装目录，未修改防火墙。' }
            $InstallPath = $dialog.SelectedPath
        }
    }
    $root = [IO.Path]::GetFullPath($InstallPath).TrimEnd('\')
    if ($Mode -in @('Remove','RemoveAutomatic','RemoveAll') -and (Test-Path -LiteralPath (Join-Path $root 'data\firewall-test-restore.txt'))) {
        throw '存在未完成的隔离测试，请先运行 restore-manual-rules.cmd。'
    }
    if ($Mode -in @('Remove','RemoveAutomatic','RemoveAll')) { $programs = @(Get-ProgramPaths $root) }
    else { $programs = @(Get-Programs $root) }
    $group = Get-RuleGroup $root ($Mode -in @('Automatic','RemoveAutomatic'))
    $description = if ($Mode -in @('Automatic','RemoveAutomatic')) { 'LightClipUniversal local subnet rule' } else { 'LightClipUniversal phone-specific rule' }
    if ($Mode -eq 'RemoveAll') {
        $oldRules = @(Get-OwnedRules (Get-RuleGroup $root) $programs) + @(Get-OwnedRules (Get-RuleGroup $root $true) $programs 'LightClipUniversal local subnet rule')
    } else { $oldRules = @(Get-OwnedRules $group $programs $description) }
    if ($Mode -in @('Remove','RemoveAutomatic','RemoveAll')) {
        foreach ($rule in $oldRules) { Remove-NetFirewallRule -Name $rule.Name -ErrorAction Stop }
        Write-Host ('已移除本安装目录创建的规则：' + $oldRules.Count)
    } elseif ($Mode -eq 'Automatic') {
        $aliases = @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { -not [String]::IsNullOrWhiteSpace($_.Name) } | ForEach-Object { [Management.Automation.WildcardPattern]::Escape($_.Name) } | Select-Object -Unique)
        if ($aliases.Count -eq 0) { throw '未找到物理网络适配器；原有规则未改变。' }
        $message = '自动模式无需输入手机 IP，也无需额外常驻进程。Windows 本地 IPv4 子网内的设备可以通过此电脑现有的物理网卡访问三个小米互联程序；范围比只允许手机 IP 更大，私人和公共网络均生效。是否继续？'
        if ([Windows.Forms.MessageBox]::Show($message, '轻剪自动网络设置', 'OKCancel', 'Warning') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，原有规则未改变。' }
        $create = { param($name,$ruleGroup,$program,$protocol,$address)
            New-NetFirewallRule -Name $name -Group $ruleGroup -DisplayName '轻剪通用版：本地网络' -Description 'LightClipUniversal local subnet rule' -Direction Inbound -Action Allow -Enabled True -Profile Public,Private -Program $program -Protocol $protocol -RemoteAddress $address -InterfaceAlias $aliases | Out-Null
        }
        $remove = { param($name) Remove-NetFirewallRule -Name $name -ErrorAction Stop }
        $oldClean = Install-PhoneRules $group $programs 'LocalSubnet4' $oldRules $create $remove
        if (-not $oldClean) { $exitCode = 1; Write-Host '新自动规则已创建，但旧自动规则未能全部清理。' }
        else { Write-Host '自动网络规则已设置。原先的手机专属规则未改动；请复制截图到手机验证。' }
    } else {
        Write-Host '请在手机当前 Wi-Fi 详情中找到“IP 地址”，不要填写“网关”。'
        $phone = Get-PhoneAddress (Read-Host '输入手机 IPv4 地址')
        $gateways = @(Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction SilentlyContinue | Where-Object { $_.NextHop -eq $phone })
        if ($gateways.Count -gt 0) {
            $answer = [Windows.Forms.MessageBox]::Show('输入的地址与电脑网关相同，通常是路由器而非手机。请确认手机 Wi-Fi 详情中的“IP 地址”确实是这个值，是否继续？', '轻剪网络设置', 'YesNo', 'Warning')
            if ($answer -ne [Windows.Forms.DialogResult]::Yes) { throw '已取消，原有规则未改变。' }
        }
        $message = '将为三个小米互联程序创建入站规则，仅允许输入的手机 IPv4 地址，适用于私人和公共网络。手机 IP 变化后需要重新设置。是否继续？'
        if ([Windows.Forms.MessageBox]::Show($message, '轻剪网络设置', 'OKCancel', 'Information') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，原有规则未改变。' }
        $create = { param($name,$ruleGroup,$program,$protocol,$address)
            New-NetFirewallRule -Name $name -Group $ruleGroup -DisplayName '轻剪通用版：指定手机' -Description 'LightClipUniversal phone-specific rule' -Direction Inbound -Action Allow -Enabled True -Profile Public,Private -Program $program -Protocol $protocol -RemoteAddress $address | Out-Null
        }
        $remove = { param($name) Remove-NetFirewallRule -Name $name -ErrorAction Stop }
        $oldClean = Install-PhoneRules $group $programs $phone $oldRules $create $remove
        if ($oldClean) { Write-Host '设置完成。请重新在电脑截图，并到手机粘贴验证。' }
        else { $exitCode = 1; Write-Host '新规则已创建，但旧规则未能全部清理；请记录上方规则名称。' }
        Write-Host '规则只针对输入的手机 IP；手机 IP 改变后请重新运行本工具。'
    }
} catch {
    $exitCode = 1
    Write-Host ('设置未完成：' + $_.Exception.Message)
}
if (-not $NoPause) { Read-Host '按回车关闭' | Out-Null }
exit $exitCode
