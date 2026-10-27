$ErrorActionPreference = 'Stop'
$taskProject = Split-Path -Parent $PSScriptRoot
$taskBuild = Join-Path $PSScriptRoot 'build'
$taskOfficial = Join-Path $taskProject 'research\private\continuity-archive-inspection\official'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskRuntime = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.NETCore.App') -Directory | Where-Object { $_.Name -match '^6\.0\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $taskRuntime) { throw '构建需要本机 .NET 6 运行时引用；测试包已内置运行时。' }
$taskReferences = @(Get-ChildItem -LiteralPath $taskRuntime.FullName -Filter '*.dll' | Where-Object {
    $_.Name -notlike '*.Native.dll' -and ($_.Name -like 'System.*' -or $_.Name -like 'Microsoft.Win32*' -or $_.Name -in @('mscorlib.dll','netstandard.dll','Microsoft.CSharp.dll'))
} | ForEach-Object { '/reference:' + $_.FullName })
New-Item -ItemType Directory -Path $taskBuild -Force | Out-Null
& $taskCompiler /noconfig /nologo /nostdlib+ /platform:x64 /target:winexe /optimize+ @taskReferences ('/reference:' + (Join-Path $taskOfficial 'MiSmartShareClrWrapper.dll')) ('/out:' + (Join-Path $taskBuild 'MiPcContinuity.dll')) (Join-Path $PSScriptRoot 'src\UniversalProgram.cs') (Join-Path $PSScriptRoot 'src\Native.cs') (Join-Path $PSScriptRoot 'src\TrayFlyout.cs')
if ($LASTEXITCODE -ne 0) { throw '通用测试程序编译失败。' }
& python (Join-Path $PSScriptRoot 'build_bundle.py')
if ($LASTEXITCODE -ne 0) { throw '安装包组件整理失败。' }
$taskOutput = Join-Path $taskBuild 'LightClipUniversal-Experimental-Setup.exe'
& $taskCompiler /nologo /platform:x64 /target:winexe /optimize+ ('/win32icon:' + (Join-Path $taskProject 'assets\lightclip.ico')) /reference:System.Windows.Forms.dll /reference:System.IO.Compression.dll /reference:System.IO.Compression.FileSystem.dll /reference:Microsoft.CSharp.dll ('/resource:' + (Join-Path $taskBuild 'payload.zip') + ',payload.zip') ('/out:' + $taskOutput) (Join-Path $PSScriptRoot 'src\UniversalSetup.cs')
if ($LASTEXITCODE -ne 0) { throw '测试安装包编译失败。' }
Write-Output "已生成实验安装包：$taskOutput"
