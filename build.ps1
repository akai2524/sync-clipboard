$ErrorActionPreference = 'Stop'
$taskRoot = $PSScriptRoot
$taskOutput = Join-Path $taskRoot 'dist'
$taskCompiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$taskRuntime = Get-ChildItem -LiteralPath (Join-Path $env:ProgramFiles 'dotnet\shared\Microsoft.NETCore.App') -Directory | Where-Object { $_.Name -match '^8\.0\.\d+$' } | Sort-Object { [version]$_.Name } -Descending | Select-Object -First 1
if (-not $taskRuntime) { throw '需要本机已安装的 .NET 8 运行时用于编译引用；不需要 SDK。' }
$taskReferences = @(Get-ChildItem -LiteralPath $taskRuntime.FullName -Filter '*.dll' | Where-Object {
    $_.Name -notlike '*.Native.dll' -and ($_.Name -like 'System.*' -or $_.Name -like 'Microsoft.Win32*' -or $_.Name -in @('mscorlib.dll','netstandard.dll','Microsoft.CSharp.dll'))
} | ForEach-Object { '/reference:' + $_.FullName })
New-Item -ItemType Directory -Path $taskOutput -Force | Out-Null
# The installed Xiaomi wrapper targets .NET 6 facade versions, unified by our existing .NET 8 host.
& $taskCompiler /noconfig /nologo /nostdlib+ /nowarn:1701 /platform:x64 /target:winexe /optimize+ @taskReferences /reference:"C:\Program Files\MI\XiaomiPCManager\5.4.0.620\MiSmartShareClrWrapper.dll" /out:"$taskOutput\XiaomiPcManager.dll" "$taskRoot\src\SyncClipboardLite.cs" "$taskRoot\src\TrayFlyout.cs" "$taskRoot\src\DeviceNames.cs"
if ($LASTEXITCODE -ne 0) { throw '编译失败。' }
Copy-Item -LiteralPath (Join-Path $taskRoot 'assets\lightclip.ico') -Destination $taskOutput -Force
'{"runtimeOptions":{"tfm":"net8.0","framework":{"name":"Microsoft.NETCore.App","version":"8.0.0"}}}' | Set-Content -LiteralPath (Join-Path $taskOutput 'XiaomiPcManager.runtimeconfig.json') -Encoding UTF8
Write-Output "编译完成：$taskOutput"
