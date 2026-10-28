"""Exercise transient and persistent deletion failures in an isolated fixture."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

parent = Path(tempfile.gettempdir()).resolve()
base = Path(tempfile.mkdtemp(prefix='LightClipCleanupRetryQa-', dir=str(parent))).resolve()
try:
    text = (Path(__file__).resolve().parents[1] / 'tools' / 'Reset-LightClipUniversal.ps1').read_text(encoding='utf-8-sig')
    start, end = 'function Remove-CleanupDirectory([string]$Path) {', '\nfunction Assert-Root([string]$Path) {'
    assert text.count(start) == 1 and text.count(end) == 1
    function = start + text.split(start, 1)[1].split(end, 1)[0]
    script = r'''
param([string]$Fixture)
$ErrorActionPreference = 'Stop'
$script:attempts = 0
function Assert-NoReparse([string]$Path) { if ($Path -ne $Fixture) { throw 'outside fixture' } }
function Start-Sleep { param($Seconds) }
function Remove-Item { param($LiteralPath,[switch]$Recurse,[switch]$Force)
    if ($LiteralPath -ne $Fixture) { throw 'outside fixture' }
    $script:attempts++
    if ($env:LIGHTCLIP_QA_FAIL -eq 'always' -or $script:attempts -lt 3) { throw 'mock access denied' }
    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath -Recurse -Force -ErrorAction Stop
}
''' + function + r'''
try {
    Remove-CleanupDirectory $Fixture
    if ($env:LIGHTCLIP_QA_FAIL -eq 'always' -or $script:attempts -ne 3 -or (Test-Path -LiteralPath $Fixture)) { exit 2 }
} catch {
    if ($env:LIGHTCLIP_QA_FAIL -ne 'always' -or $script:attempts -ne 5 -or $_.Exception.Message.IndexOf($Fixture) -lt 0 -or -not (Test-Path -LiteralPath $Fixture)) { exit 3 }
}
'''
    path = base / 'test.ps1'
    path.write_text(script, encoding='utf-8-sig')
    for mode in ('transient', 'always'):
        fixture = base / mode
        fixture.mkdir()
        (fixture / 'file').write_text('fixture')
        env = dict(os.environ, LIGHTCLIP_QA_FAIL=mode)
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(path), '-Fixture', str(fixture)], env=env, capture_output=True, timeout=20)
        assert result.returncode == 0, (mode, result.stdout, result.stderr)
    print('Cleanup retry tests passed for transient and persistent errors.')
finally:
    assert base.parent == parent and base.name.startswith('LightClipCleanupRetryQa-') and not base.is_symlink()
    shutil.rmtree(base)
