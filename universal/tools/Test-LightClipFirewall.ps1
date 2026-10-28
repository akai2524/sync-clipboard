param([switch]$InspectOnly, [string]$InstallPath)

$ErrorActionPreference = 'Stop'

function Get-OfficialPrograms([string]$Root) {
    $names = @('MiPcContinuity.exe', 'micont_service.exe', 'x86\MiPcContinuityService.exe')
    $programs = @()
    if (-not (Test-Path -LiteralPath (Join-Path $Root 'MiPcContinuity.dll') -PathType Leaf)) {
        throw '所选目录不是轻剪通用版安装目录。'
    }
    foreach ($name in $names) {
        $path = Join-Path $Root $name
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw ('缺少文件：' + $name) }
        $signature = Get-AuthenticodeSignature -LiteralPath $path
        if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'CN="?Xiaomi Communications Co\., Ltd\."?') {
            throw ('官方签名验证失败：' + $name + '，状态：' + $signature.Status)
        }
        $programs += $path
    }
    return $programs
}

if ($InspectOnly) {
    if (-not $InstallPath) { throw 'InspectOnly 需要指定 InstallPath。' }
    $programs = @(Get-OfficialPrograms ([IO.Path]::GetFullPath($InstallPath)))
    if ($programs.Count -ne 3) { throw '程序数量不正确。' }
    Write-Output '官方程序签名检查通过；未更改防火墙。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $arguments | Out-Null
    } catch { Write-Host '未获得管理员授权，未更改防火墙。'; Read-Host '按回车关闭' | Out-Null }
    exit
}

$created = New-Object 'System.Collections.Generic.List[string]'
try {
    Add-Type -AssemblyName System.Windows.Forms
    $dialog = New-Object System.Windows.Forms.FolderBrowserDialog
    $dialog.Description = '请选择轻剪通用版安装目录'
    $dialog.ShowNewFolderButton = $false
    if (Test-Path -LiteralPath 'D:\Apps\LightClipUniversal') { $dialog.SelectedPath = 'D:\Apps\LightClipUniversal' }
    if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '未选择安装目录。' }
    $programs = @(Get-OfficialPrograms ([IO.Path]::GetFullPath($dialog.SelectedPath)))
    Write-Host '请在手机当前 Wi-Fi 的网络详情中查找 IPv4 地址，例如 192.168.1.23。'
    $entered = (Read-Host '输入手机 IPv4 地址').Trim()
    $phone = $null
    if (-not [Net.IPAddress]::TryParse($entered, [ref]$phone) -or $phone.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) {
        throw '地址格式不正确，需要手机的 IPv4 地址。'
    }
    $octets = $phone.GetAddressBytes()
    $isPrivate = $octets[0] -eq 10 -or ($octets[0] -eq 172 -and $octets[1] -ge 16 -and $octets[1] -le 31) -or ($octets[0] -eq 192 -and $octets[1] -eq 168) -or ($octets[0] -eq 169 -and $octets[1] -eq 254)
    if (-not $isPrivate) { throw '该地址不是受支持的局域网 IPv4 地址；未修改防火墙。' }
    $reply = [Windows.Forms.MessageBox]::Show('将临时允许该手机 IPv4 地址访问三个小米互联程序（公共网络，TCP/UDP）。测试完成后按回车，工具会删除刚创建的规则。请在可信网络上测试。', '轻剪图片同步诊断', 'OKCancel', 'Information')
    if ($reply -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未更改防火墙。' }

    $tag = [Guid]::NewGuid().ToString('N')
    $index = 0
    foreach ($program in $programs) {
        foreach ($protocol in @('TCP', 'UDP')) {
            $name = 'LightClipTest-' + $tag + '-' + $index
            New-NetFirewallRule -Name $name -DisplayName 'LightClip temporary image test' -Direction Inbound -Action Allow -Enabled True -Profile Public -Program $program -Protocol $protocol -RemoteAddress $phone.ToString() | Out-Null
            $created.Add($name)
            $index++
        }
    }
    Write-Host '临时规则已添加。请重新在电脑截图，再到手机便签粘贴，观察是否成功。'
    Read-Host '测试后回到此窗口按回车，清理临时规则' | Out-Null
} catch {
    Write-Host ('测试未完成：' + $_.Exception.Message)
} finally {
    foreach ($name in $created) {
        try { Remove-NetFirewallRule -Name $name -ErrorAction Stop } catch { Write-Host ('清理失败：' + $name) }
    }
    if ($created.Count -gt 0) { Write-Host '清理步骤已完成；如出现清理失败，请保留失败的规则名称。' }
}
Read-Host '按回车关闭' | Out-Null
