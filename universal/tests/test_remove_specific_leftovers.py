"""Test specific-folder cleanup using only freshly created temporary fixtures."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

parent = Path(tempfile.gettempdir()).resolve()
base = Path(tempfile.mkdtemp(prefix='LightClipLeftoversQa-', dir=str(parent))).resolve()
try:
    source = (Path(__file__).resolve().parents[1] / 'tools' / 'Remove-LightClipSpecificLeftovers.ps1').read_text(encoding='utf-8-sig')
    original = r'E:\LightClipUniversal-cleanup-e5eddb5002d4456a859f7b011e432f7c'
    assert source.count(original) == 2
    admin = '$isAdmin = ([Security.Principal.WindowsPrincipal] [Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)'
    assert source.count(admin) == 1
    source = source.replace(admin, '$isAdmin = $true')
    dialog = "    if ([Windows.Forms.MessageBox]::Show($message, '轻剪卸载剩余文件', 'OKCancel', 'Warning') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未删除。' }"
    assert source.count(dialog) == 1
    source = source.replace(dialog, '    # Confirmed in isolated test.')
    source = source.replace("Read-Host '按回车关闭' | Out-Null", '$null = 0')
    source = source.replace("    foreach ($name in @('MiPcContinuityService','micont_service')) {", r'''    function Get-CimInstance { param($ClassName, $Filter)
        if ($env:LIGHTCLIP_QA_SERVICE -eq 'present') { return [PSCustomObject]@{ PathName = $root + '\\micont_service.exe' } }
        return $null
    }
    foreach ($name in @('MiPcContinuityService','micont_service')) {''')
    for mode in ('normal', 'service'):
        root = base / mode / 'LightClipUniversal-cleanup-e5eddb5002d4456a859f7b011e432f7c'
        root.mkdir(parents=True)
        (root / 'file.dll').write_bytes(b'fixture')
        sibling = root.parent / 'preserve.txt'
        sibling.write_text('keep')
        script = base / (mode + '.ps1')
        script.write_text(source.replace(original, str(root)), encoding='utf-8-sig')
        env = dict(os.environ, LIGHTCLIP_QA_SERVICE='present' if mode == 'service' else '')
        result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)], env=env, capture_output=True, timeout=20)
        assert result.returncode == (1 if mode == 'service' else 0), (mode, result.stdout, result.stderr)
        assert sibling.read_text() == 'keep'
        assert root.exists() == (mode == 'service'), (mode, result.stdout, result.stderr)
    print('Specific-folder removal tests passed; service guard and sibling preservation verified.')
finally:
    assert base.parent == parent and base.name.startswith('LightClipLeftoversQa-') and not base.is_symlink()
    shutil.rmtree(base)
