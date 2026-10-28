"""Exercise cleanup's service-permission recovery with simulated Windows services.

The script never modifies real services, firewall rules, or installed applications.
"""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[2]
TOOLS = ROOT / 'universal' / 'tools'


def main():
    parent = Path(tempfile.gettempdir()).resolve()
    base = Path(tempfile.mkdtemp(prefix='LightClipResetDaclQa-', dir=str(parent)))
    try:
        source = (TOOLS / 'Reset-LightClipUniversal.ps1').read_text(encoding='utf-8-sig')
        library = (TOOLS / 'Configure-LightClipFirewall.ps1').read_text(encoding='utf-8-sig')
        real_helper = (TOOLS / 'LightClipServiceSecurity.ps1').read_text(encoding='utf-8-sig')
        (base / 'Configure-LightClipFirewall.ps1').write_text(library, encoding='utf-8-sig')
        marker = 'function Get-StopEnabledDescriptor'
        assert real_helper.count(marker) == 1
        fake_helper = r'''
Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Security.AccessControl;
public static class LightClipServiceSecurity {
 public static byte[] Original;
 public static byte[] Current;
 static LightClipServiceSecurity() {
  var d=new RawSecurityDescriptor("D:(D;;0x22;;;WD)(D;;0x22;;;SY)(A;;0xF01FF;;;BA)");
  Original=new byte[d.BinaryLength]; d.GetBinaryForm(Original,0); Current=(byte[])Original.Clone();
 }
 static bool HasWorldDeny(byte[] b) {
  var d=new RawSecurityDescriptor(b,0);
  foreach(GenericAce g in d.DiscretionaryAcl) { var a=g as CommonAce; if(a!=null && a.AceQualifier==AceQualifier.AccessDenied && a.SecurityIdentifier.Value=="S-1-1-0" && (a.AccessMask&32)!=0) return true; }
  return false;
 }
 public static int CheckStop(string name) { return HasWorldDeny(Current) ? 5 : 0; }
 public static byte[] ReadDacl(string name) { return (byte[])Current.Clone(); }
 public static void WriteDacl(string name,byte[] value) {
  bool restoring=HasWorldDeny(value);
  File.AppendAllText(Environment.GetEnvironmentVariable("LIGHTCLIP_FAKE_LOG"),restoring?"restore\n":"grant\n");
  if(restoring && Environment.GetEnvironmentVariable("LIGHTCLIP_FAIL_RESTORE")=="1") throw new Exception("mock restore failed");
  Current=(byte[])value.Clone();
 }
}
'@
'''
        (base / 'LightClipServiceSecurity.ps1').write_text(fake_helper + '\n' + marker + real_helper.split(marker, 1)[1], encoding='utf-8-sig')
        anchor = ". (Join-Path $PSScriptRoot 'LightClipServiceSecurity.ps1')"
        mocks = r'''
[Console]::OutputEncoding = New-Object System.Text.UTF8Encoding($false)
Add-Type -AssemblyName System.ServiceProcess
function Get-AuthenticodeSignature { [CmdletBinding()] param($LiteralPath) [PSCustomObject]@{ Status='Valid'; SignerCertificate=[PSCustomObject]@{ Subject='CN="Xiaomi Communications Co., Ltd."' } } }
function Test-Path { [CmdletBinding()] param($LiteralPath,$PathType) if ([string]$LiteralPath -like 'Registry::HKEY_USERS*') { return $true }; Microsoft.PowerShell.Management\Test-Path @PSBoundParameters }
function Get-ItemProperty { [CmdletBinding()] param($LiteralPath) [PSCustomObject]@{ LightClipUniversal=$null } }
function Get-NetFirewallRule { [CmdletBinding()] param($Group,$Name) return }
function Get-CimInstance {
 [CmdletBinding()] param($ClassName,$Filter)
 if ($Filter -eq "Name='MiPcContinuityService'") { return [PSCustomObject]@{ PathName=('"' + (Join-Path $TargetPath 'x86\MiPcContinuityService.exe') + '" /service') } }
}
function Get-Service {
 [CmdletBinding()] param($Name)
 $o=[PSCustomObject]@{ Status='Running' }
 $o | Add-Member -MemberType ScriptMethod -Name Dispose -Value {}
 $o | Add-Member -MemberType ScriptMethod -Name WaitForStatus -Value { param($status,$timeout) }
 return $o
}
function Stop-Service {
 [CmdletBinding()] param($Name)
 if ([LightClipServiceSecurity]::CheckStop($Name) -ne 0) { throw 'mock stop permission denied' }
 if ($env:LIGHTCLIP_FAIL_STOP -eq '1') { throw 'mock stop failed after grant' }
 Add-Content -LiteralPath $env:LIGHTCLIP_FAKE_LOG -Value 'stop'
}
function Invoke-FakeServiceDelete { param($Name) Add-Content -LiteralPath $env:LIGHTCLIP_FAKE_LOG -Value ('delete ' + $Name); $global:LASTEXITCODE=0 }
function Start-Process { [CmdletBinding()] param($FilePath,$ArgumentList,$WindowStyle,[switch]$PassThru) $o=[PSCustomObject]@{}; $o | Add-Member -MemberType ScriptMethod -Name WaitForExit -Value { param($ms) return $true }; return $o }
function Get-Process { [CmdletBinding()] param($Name) return }
'''
        assert source.count(anchor) == 1
        source = source.replace(anchor, anchor + '\n' + mocks)
        assert source.count('    Assert-NotXiaomiPc\n') == 1
        source = source.replace('    Assert-NotXiaomiPc\n', '    # Isolated test guard.\n')
        guard = "if (-not ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { throw '未获得管理员权限，未执行清理。' }"
        assert source.count(guard) == 1
        source = source.replace(guard, 'if ($false) { throw "mock admin error" }')
        call = "& (Join-Path $env:WINDIR 'System32\\sc.exe') delete $item.Name | Out-Null"
        assert source.count(call) == 1
        source = source.replace(call, 'Invoke-FakeServiceDelete $item.Name')
        source = source.replace("Read-Host '按回车关闭' | Out-Null", '$null = 0')
        script = base / 'mock-reset.ps1'
        script.write_text(source, encoding='utf-8-sig')
        for label, fail_stop, fail_restore in [('success', '0', '0'), ('stop-failed', '1', '0'), ('restore-failed', '0', '1')]:
            work = base / label
            root = work / 'LightClipUniversal'
            (root / 'x86').mkdir(parents=True)
            (root / 'data').mkdir()
            for name in ['MiPcContinuity.dll', 'MiPcContinuity.exe', 'micont_service.exe', 'x86/MiPcContinuityService.exe', 'lightclip.ico', 'uninstall.ps1']:
                (root / name).write_bytes(b'fake')
            desktop = work / 'desktop'
            desktop.mkdir()
            log = work / 'events.txt'
            env = os.environ.copy()
            env.update(LIGHTCLIP_FAKE_LOG=str(log), LIGHTCLIP_FAIL_STOP=fail_stop, LIGHTCLIP_FAIL_RESTORE=fail_restore)
            args = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script), '-Phase', 'Elevated', '-TargetPath', str(root), '-UserSid', 'S-1-5-21-1-2-3-1001', '-DesktopPath', str(desktop)]
            process = subprocess.run(args, capture_output=True, encoding='utf-8', errors='replace', env=env, timeout=30)
            events = log.read_text().splitlines() if log.exists() else []
            snapshot = root / 'data' / 'LightClipUniversal-reset-service.original-dacl'
            if label == 'success':
                good = process.returncode == 0 and not root.exists() and events == ['grant', 'stop', 'restore', 'delete MiPcContinuityService']
            elif label == 'stop-failed':
                good = process.returncode != 0 and root.exists() and not snapshot.exists() and events == ['grant', 'restore']
            else:
                good = process.returncode != 0 and root.exists() and snapshot.exists() and events == ['grant', 'stop', 'restore']
            if not good:
                raise RuntimeError(f'{label}: code={process.returncode}, events={events!r}, output={process.stdout!r}, error={process.stderr!r}')
            if label == 'restore-failed':
                env['LIGHTCLIP_FAIL_RESTORE'] = '0'
                retry = subprocess.run(args, capture_output=True, encoding='utf-8', errors='replace', env=env, timeout=30)
                events = log.read_text().splitlines()
                expected = ['grant', 'stop', 'restore', 'restore', 'grant', 'stop', 'restore', 'delete MiPcContinuityService']
                if retry.returncode != 0 or root.exists() or events != expected:
                    raise RuntimeError(f'interrupted recovery: code={retry.returncode}, events={events!r}, output={retry.stdout!r}, error={retry.stderr!r}')
        print('Cleanup service-permission integration simulations passed.')
    finally:
        if base.parent.resolve() == parent and base.name.startswith('LightClipResetDaclQa-') and not base.is_symlink():
            shutil.rmtree(base)


if __name__ == '__main__':
    main()
