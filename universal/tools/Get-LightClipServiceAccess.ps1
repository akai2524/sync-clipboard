param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class LightClipServiceAccess {
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
    private static extern IntPtr OpenSCManagerW(string machine, string database, uint access);
    [DllImport("advapi32.dll", SetLastError=true, CharSet=CharSet.Unicode, ExactSpelling=true)]
    private static extern IntPtr OpenServiceW(IntPtr manager, string service, uint access);
    [DllImport("advapi32.dll", SetLastError=true, ExactSpelling=true)]
    private static extern bool CloseServiceHandle(IntPtr handle);
    public static int Check(string name, uint access) {
        IntPtr manager = OpenSCManagerW(null, null, 1);
        if (manager == IntPtr.Zero) return Marshal.GetLastWin32Error();
        try {
            IntPtr service = OpenServiceW(manager, name, access);
            if (service == IntPtr.Zero) return Marshal.GetLastWin32Error();
            CloseServiceHandle(service);
            return 0;
        } finally { CloseServiceHandle(manager); }
    }
}
'@

if ($SelfTest) {
    $name = 'LightClip-Nonexistent-' + [Guid]::NewGuid().ToString('N')
    if ([LightClipServiceAccess]::Check($name, 4) -ne 1060) { throw '服务权限查询自检失败。' }
    Write-Output '服务权限查询自检通过；未更改服务。'
    exit 0
}

if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    try {
        $psExe = Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + $PSCommandPath + '"'
        $child = Start-Process -FilePath $psExe -Verb RunAs -ArgumentList $arguments -PassThru -Wait
        exit $child.ExitCode
    } catch { Write-Host '未获得管理员授权；未更改服务。'; Read-Host '按回车关闭' | Out-Null; exit 1 }
}

$exitCode = 0
try {
    $name = 'MiPcContinuityService'
    $service = Get-CimInstance -ClassName Win32_Service -Filter "Name='MiPcContinuityService'" -ErrorAction Stop
    if ($null -eq $service) {
        Write-Host '服务状态：未安装'
    } else {
        Write-Host ('服务状态：' + $service.State)
        $path = [Environment]::ExpandEnvironmentVariables($service.PathName)
        $belongs = $path -match '^\s*"?[^"\r\n]*\\LightClipUniversal\\x86\\MiPcContinuityService\.exe"?(?:\s|$)'
        Write-Host ('服务程序位于旧版轻剪目录：' + $(if ($belongs) { '是' } else { '否或无法判断' }))
        try {
            $view = Get-Service -Name $name -ErrorAction Stop
            Write-Host ('服务报告可停止：' + $(if ($view.CanStop) { '是' } else { '否' }))
            $dependents = @($view.DependentServices | Where-Object { $_.Status -ne 'Stopped' }).Count
            Write-Host ('正在运行的依赖服务数量：' + $dependents)
            $view.Dispose()
        } catch { Write-Host '服务可停止状态或依赖数量：无法读取' }
        foreach ($item in @(
            @{ Name='查询状态权限'; Access=4 },
            @{ Name='停止权限'; Access=32 },
            @{ Name='查询和停止组合权限'; Access=36 },
            @{ Name='删除权限'; Access=65536 },
            @{ Name='读取安全设置权限'; Access=131072 },
            @{ Name='修改安全设置权限'; Access=262144 }
        )) {
            $code = [LightClipServiceAccess]::Check($name, $item.Access)
            Write-Host ($item.Name + '：' + $(if ($code -eq 0) { '允许' } else { '未获得，错误码=' + $code }))
        }
    }
    Write-Host '本检查只读取服务状态和权限，没有停止、修改或删除服务。'
} catch {
    $exitCode = 1
    Write-Host '检查未完成，无法读取所需服务信息；没有修改服务。'
}
Read-Host '按回车关闭' | Out-Null
exit $exitCode
