"""Build an experimental one-file installer from a verified local Xiaomi archive.

This script is for the user's private test. It does not run Xiaomi components or
modify the installed Xiaomi-PC edition. Third-party files remain vendor-signed.
"""
from pathlib import Path
from collections import deque
import hashlib
import json
import sys
import zipfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / '.tools' / 'python'))
import pefile

official = ROOT / 'research/private/continuity-archive-inspection/official'
installer = ROOT / 'research/private/PcContinuity_1.1.2.36_official.exe'
build = ROOT / 'universal/build'
app = build / 'MiPcContinuity.dll'
if not official.is_dir() or not app.is_file() or not installer.is_file():
    raise SystemExit('官方安装包、离线提取目录或编译产物缺失。')
checksum = hashlib.md5()
with installer.open('rb') as stream:
    for block in iter(lambda: stream.read(4 * 1024 * 1024), b''):
        checksum.update(block)
if checksum.hexdigest().lower() != '5e2236eec98b71d61874d0162cf91fba':
    raise SystemExit('官方安装包校验失败。')

files = {p.name.lower(): p for p in official.iterdir() if p.is_file()}
official_deps = json.loads((official / 'MiPcContinuity.deps.json').read_text(encoding='utf-8'))
target_name = official_deps['runtimeTarget']['name']
official_target = official_deps['targets'][target_name]
runtime_name = next(name for name in official_target if name.startswith('runtimepack.Microsoft.NETCore.App.Runtime.win-x64/'))
app_name = next(name for name in official_target if name.startswith('MiPcContinuity/'))
runtime_manifest = dict(official_target[runtime_name])
# The vendor package omits one version-suffixed debugging DAC listed in its
# manifest. It is not needed for normal execution; retain all files present.
for kind in ('runtime', 'native'):
    runtime_manifest[kind] = {name: metadata for name, metadata in runtime_manifest.get(kind, {}).items()
                              if (official / name).is_file()}
todo = deque(['MiPcContinuity.exe', 'MiSmartShareClrWrapper.dll', 'MiSmartShareDLL.dll',
              'micont_service.exe', 'FixServiceTool.exe'])
native = set()
while todo:
    name = todo.popleft().lower()
    if name in native:
        continue
    source = files.get(name)
    if source is None:
        raise SystemExit('缺少官方组件：' + name)
    native.add(name)
    try:
        pe = pefile.PE(str(source), fast_load=True)
        pe.parse_data_directories(directories=[pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_IMPORT'],
                                               pefile.DIRECTORY_ENTRY['IMAGE_DIRECTORY_ENTRY_DELAY_IMPORT']])
        for table in ('DIRECTORY_ENTRY_IMPORT', 'DIRECTORY_ENTRY_DELAY_IMPORT'):
            for item in getattr(pe, table, []):
                dep = item.dll.decode('ascii', 'ignore').lower()
                if dep in files and dep not in native:
                    todo.append(dep)
    except pefile.PEFormatError:
        pass

selected = {}
runtime_files = set()
for kind in ('runtime', 'native'):
    runtime_files.update(runtime_manifest.get(kind, {}).keys())
for name, source in files.items():
    if (name in native or name.startswith('system.') and name.endswith('.dll')
        or name.startswith('microsoft.win32.') and name.endswith('.dll')
        or name in {'microsoft.csharp.dll', 'mscorlib.dll', 'netstandard.dll', 'winrt.runtime.dll',
                    'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll', 'clrjit.dll', 'ijwhost.dll',
                    'mipccontinuity.runtimeconfig.json'} or source.name in runtime_files):
        selected[source.name] = source
# The official service repair and login paths refer to these supporting folders.
for folder in ('micloud', 'x86', 'Assets/Privacy', 'Assets/privacy_content'):
    base = official / folder
    if base.is_dir():
        for source in base.rglob('*'):
            if source.is_file():
                selected[source.relative_to(official).as_posix()] = source
selected['MiPcContinuity.dll'] = app
selected['lightclip.ico'] = ROOT / 'assets/lightclip.ico'
selected['uninstall.ps1'] = ROOT / 'universal/src/uninstall.ps1'
selected['卸载测试版.cmd'] = ROOT / 'universal/src/卸载测试版.cmd'
for name in ('Repair-LightClipServices.ps1', 'repair-services.cmd',
             'Configure-LightClipFirewall.ps1', 'configure-firewall.cmd', 'remove-firewall.cmd'):
    selected['tools/' + name] = ROOT / 'universal/tools' / name

# The signed apphost detects self-contained mode from this file. Keep the
# official .NET 6 runtime manifest while omitting the original GUI's packages.
missing_runtime = [name for name in runtime_files if name not in selected]
if missing_runtime:
    raise SystemExit('缺少自包含运行时文件：' + ', '.join(missing_runtime))
app_manifest = {'runtime': {'MiPcContinuity.dll': {}, 'MiSmartShareClrWrapper.dll': {}}}
deps = {'runtimeTarget': official_deps['runtimeTarget'], 'compilationOptions': {},
        'targets': {target_name: {app_name: app_manifest, runtime_name: runtime_manifest}},
        'libraries': {app_name: official_deps['libraries'][app_name], runtime_name: official_deps['libraries'][runtime_name]}}
deps_path = build / 'MiPcContinuity.deps.json'
deps_path.write_text(json.dumps(deps, ensure_ascii=False, separators=(',', ':')), encoding='utf-8')
selected['MiPcContinuity.deps.json'] = deps_path

mandatory = ['MiPcContinuity.exe', 'MiPcContinuity.dll', 'MiPcContinuity.deps.json', 'MiPcContinuity.runtimeconfig.json',
             'MiSmartShareClrWrapper.dll', 'MiSmartShareDLL.dll', 'dist_clipboard.dll',
             'micont_service.exe', 'x86/MiPcContinuityService.exe', 'FixServiceTool.exe',
             'tools/Repair-LightClipServices.ps1', 'tools/Configure-LightClipFirewall.ps1',
             'hostfxr.dll', 'hostpolicy.dll', 'coreclr.dll']
for item in mandatory:
    if item not in selected:
        raise SystemExit('缺少安装组件：' + item)

out = build / 'payload.zip'
with zipfile.ZipFile(out, 'w', compression=zipfile.ZIP_DEFLATED, compresslevel=6, allowZip64=True) as archive:
    for name, source in sorted(selected.items()):
        if name == 'uninstall.ps1':
            # Windows PowerShell 5.1 needs a BOM to read Chinese paths and text.
            archive.writestr(name, source.read_text(encoding='utf-8').encode('utf-8-sig'))
        else:
            archive.write(source, name)
print(json.dumps({'files': len(selected), 'native_dependency_files': len(native),
                  'uncompressed_mb': round(sum(p.stat().st_size for p in selected.values()) / 1048576, 1),
                  'compressed_mb': round(out.stat().st_size / 1048576, 1)}, ensure_ascii=False))
