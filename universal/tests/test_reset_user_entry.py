"""Exercise the real user-phase path selection without touching services or files."""
from pathlib import Path
import os
import shutil
import subprocess
import tempfile

tools = Path(__file__).resolve().parents[1] / 'tools'
parent = Path(tempfile.gettempdir()).resolve()
base = Path(tempfile.mkdtemp(prefix='LightClipResetUserQa-', dir=str(parent))).resolve()
try:
    for name in ('Configure-LightClipFirewall.ps1', 'LightClipServiceSecurity.ps1'):
        shutil.copyfile(tools / name, base / name)
    source = (tools / 'Reset-LightClipUniversal.ps1').read_text(encoding='utf-8-sig')
    anchor = '    Assert-NotXiaomiPc\n'
    assert source.count(anchor) == 1
    source = source.replace(anchor, r'''
    function Assert-Root([string]$Path) {
        if ($Path -ne 'E:\LightClipUniversal') { throw ('incorrect path: ' + $Path) }
        return $Path
    }
    function Find-InstallRoots {
        if ($env:LIGHTCLIP_QA_MODE -eq 'one') { return 'E:\LightClipUniversal' }
        return @('E:\LightClipUniversal', 'C:\Apps\LightClipUniversal')
    }
    function Start-Process { param($FilePath,$Verb,$ArgumentList,[switch]$PassThru,[switch]$Wait)
        [IO.File]::WriteAllText($env:LIGHTCLIP_QA_MARKER, $ArgumentList)
        return [PSCustomObject]@{ ExitCode = 0 }
    }
''')
    line = "        if ([Windows.Forms.MessageBox]::Show($text, '轻剪旧版一键清理', 'OKCancel', 'Warning') -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未执行清理。' }"
    assert source.count(line) == 1
    source = source.replace(line, '        # Mock user confirmation only in this isolated test.')
    source = source.replace("Read-Host '按回车关闭' | Out-Null", '$null = 0')
    script = base / 'mock-reset.ps1'
    script.write_text(source, encoding='utf-8-sig')
    for mode in ('explicit', 'one', 'multiple'):
        marker = base / (mode + '.txt')
        env = dict(os.environ, LIGHTCLIP_QA_MODE=mode, LIGHTCLIP_QA_MARKER=str(marker))
        cmd = ['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(script)]
        if mode == 'explicit':
            cmd += ['-TargetPath', r'E:\LightClipUniversal']
        result = subprocess.run(cmd, env=env, capture_output=True, timeout=20)
        if mode == 'multiple':
            assert result.returncode != 0 and not marker.exists(), (mode, result.stdout, result.stderr)
        else:
            assert result.returncode == 0 and marker.exists(), (mode, result.stdout, result.stderr)
            assert '-TargetPath "E:\\LightClipUniversal"' in marker.read_text(), mode
    print('Uninstaller user-phase path selection passed: explicit, one, multiple.')
finally:
    assert base.parent == parent and base.name.startswith('LightClipResetUserQa-') and not base.is_symlink()
    shutil.rmtree(base)
