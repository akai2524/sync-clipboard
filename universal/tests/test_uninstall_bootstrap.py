import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import time

base = Path(tempfile.mkdtemp(prefix='LightClipUninstallQa-')).resolve()
assert base.name.startswith('LightClipUninstallQa-') and base.parent == Path(tempfile.gettempdir()).resolve()
root = base / 'LightClipUniversal'
tools = root / 'tools'
tools.mkdir(parents=True)
try:
    source = Path(__file__).resolve().parents[1] / 'src' / 'uninstall.ps1'
    # Windows PowerShell 5.1 reads UTF-8 without a BOM as the system ANSI code
    # page. Parse the actual packaged source before the fixture rewrites it.
    assert source.read_bytes().startswith(b'\xef\xbb\xbf'), 'uninstall.ps1 must be UTF-8 with BOM'
    parse = subprocess.run([
        'powershell.exe', '-NoProfile', '-Command',
        '$tokens=$null; $errors=$null; '
        '[System.Management.Automation.Language.Parser]::ParseFile($env:LIGHTCLIP_QA_SOURCE, [ref]$tokens, [ref]$errors) | Out-Null; '
        'if ($errors.Count) { $errors | Out-String | Write-Error; exit 1 }'
    ], env=dict(os.environ, LIGHTCLIP_QA_SOURCE=str(source)), capture_output=True, timeout=20)
    assert parse.returncode == 0, (parse.stdout, parse.stderr)
    content = source.read_text(encoding='utf-8-sig').replace('-PassThru -Wait | Out-Null', '-WindowStyle Hidden -PassThru -Wait | Out-Null')
    (root / 'uninstall.ps1').write_text(content, encoding='utf-8-sig')
    marker = base / 'called.txt'
    fake = "param([string]$TargetPath)\n[IO.File]::WriteAllText($env:LIGHTCLIP_QA_MARKER, $TargetPath)\n"
    (tools / 'Reset-LightClipUniversal.ps1').write_text(fake, encoding='utf-8-sig')
    for name in ('Configure-LightClipFirewall.ps1', 'LightClipServiceSecurity.ps1'):
        (tools / name).write_text('# fake\n', encoding='utf-8-sig')
    env = dict(os.environ, LIGHTCLIP_QA_MARKER=str(marker))
    result = subprocess.run(['powershell.exe', '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', str(root / 'uninstall.ps1')], env=env, capture_output=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and (not marker.exists() or list(base.glob('LightClipUninstall-*'))):
        time.sleep(.2)
    assert marker.exists(), '模拟卸载程序没有收到调用'
    assert marker.read_text() == str(root)
    assert not list(base.glob('LightClipUninstall-*')), '临时目录未清理'
    assert root.exists(), '模拟卸载不能删除真实安装目录'
    marker.unlink()
    batch = Path(__file__).resolve().parents[1] / 'src' / '卸载轻剪.cmd'
    shutil.copyfile(batch, root / '卸载轻剪.cmd')
    result = subprocess.run(['cmd.exe', '/c', str(root / '卸载轻剪.cmd')], env=env, capture_output=True, timeout=20)
    assert result.returncode == 0, (result.stdout, result.stderr)
    deadline = time.monotonic() + 20
    while time.monotonic() < deadline and (not marker.exists() or list(base.glob('LightClipUninstall-*'))):
        time.sleep(.2)
    assert marker.exists() and marker.read_text() == str(root), '批处理入口未正确传递安装目录'
    assert not list(base.glob('LightClipUninstall-*')), '批处理入口的暂存目录未清理'
    print('卸载启动与暂存清理模拟测试通过；未修改任何服务或规则。')
finally:
    assert base.name.startswith('LightClipUninstallQa-') and base.parent == Path(tempfile.gettempdir()).resolve()
    for attempt in range(30):
        try:
            shutil.rmtree(base)
            break
        except PermissionError:
            if attempt == 29:
                raise
            time.sleep(.2)
