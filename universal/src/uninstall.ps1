$ErrorActionPreference = 'Stop'
$taskStage = $null
try {
    $taskRoot = [IO.Path]::GetFullPath($PSScriptRoot).TrimEnd('\')
    $dirName = [IO.Path]::GetFileName($taskRoot)
    if ($dirName -ne 'LightClipUniversal' -and $dirName -notmatch '^LightClipUniversal-cleanup-[0-9a-f]{32}$') {
        throw ('安装目录检查失败：当前文件夹是 ' + $taskRoot + '。请从安装时创建的 LightClipUniversal 文件夹运行卸载。')
    }
    $taskCheck = Get-Item -LiteralPath $taskRoot -Force
    while ($taskCheck) {
        if (($taskCheck.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw '安装路径包含重解析点，已停止卸载。' }
        $taskCheck = $taskCheck.Parent
    }
    $taskParent = [IO.Directory]::GetParent($taskRoot).FullName
    $taskStage = Join-Path $taskParent ('LightClipUninstall-' + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $taskStage -ErrorAction Stop | Out-Null
    $toolsDir = Join-Path $taskRoot 'tools'
    $hasTools = Test-Path -LiteralPath (Join-Path $toolsDir 'Reset-LightClipUniversal.ps1') -PathType Leaf

    if ($hasTools) {
        $taskFiles = @('Reset-LightClipUniversal.ps1','Configure-LightClipFirewall.ps1','LightClipServiceSecurity.ps1')
        foreach ($taskName in $taskFiles) {
            $srcFile = Join-Path $toolsDir $taskName
            if (Test-Path -LiteralPath $srcFile -PathType Leaf) {
                Copy-Item -LiteralPath $srcFile -Destination (Join-Path $taskStage $taskName) -ErrorAction Stop
            }
        }
    }

    $taskRootQuoted = $taskRoot.Replace("'", "''")
    $taskStageQuoted = $taskStage.Replace("'", "''")
    $taskParentQuoted = $taskParent.Replace("'", "''")
    $taskPid = $PID
    $taskWrapper = @"
`$ErrorActionPreference = 'Stop'
`$taskStage = '$taskStageQuoted'
`$taskParent = '$taskParentQuoted'
try {
    Wait-Process -Id $taskPid -ErrorAction SilentlyContinue -Timeout 30
    `$resetScript = Join-Path `$taskStage 'Reset-LightClipUniversal.ps1'
    if (Test-Path -LiteralPath `$resetScript) {
        `$arguments = '-NoProfile -ExecutionPolicy Bypass -File "' + `$resetScript + '" -TargetPath "' + '$taskRootQuoted' + '"'
        Start-Process -FilePath 'powershell.exe' -ArgumentList `$arguments -WorkingDirectory `$taskStage -PassThru -Wait | Out-Null
    } else {
        # 若为历史残留目录且缺少 tools，安全清理残留
        `$target = '$taskRootQuoted'
        if ([IO.Path]::GetFileName(`$target) -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$' -and (Test-Path -LiteralPath `$target)) {
            for (`$i = 1; `$i -le 10; `$i++) {
                try {
                    Get-ChildItem -LiteralPath `$target -Recurse -Force -ErrorAction SilentlyContinue | ForEach-Object {
                        if (`$_.Attributes -band [IO.FileAttributes]::ReadOnly) { `$_.Attributes = `$_.Attributes -bxor [IO.FileAttributes]::ReadOnly }
                    }
                    Remove-Item -LiteralPath `$target -Recurse -Force -ErrorAction Stop
                    break
                } catch { Start-Sleep -Milliseconds 200 }
            }
        }
    }
} finally {
    if ([IO.Path]::GetDirectoryName(`$taskStage) -eq `$taskParent -and [IO.Path]::GetFileName(`$taskStage) -match '^LightClipUninstall-[0-9a-f]{32}$' -and (Test-Path -LiteralPath `$taskStage)) {
        `$item = Get-Item -LiteralPath `$taskStage -Force
        if ((`$item.Attributes -band [IO.FileAttributes]::ReparsePoint) -eq 0) {
            foreach (`$name in @('Reset-LightClipUniversal.ps1','Configure-LightClipFirewall.ps1','LightClipServiceSecurity.ps1')) {
                Remove-Item -LiteralPath (Join-Path `$taskStage `$name) -Force -ErrorAction SilentlyContinue
            }
            Remove-Item -LiteralPath `$taskStage -Force -ErrorAction SilentlyContinue
        }
    }
}
"@
    $taskEncoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($taskWrapper))
    Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-ExecutionPolicy','Bypass','-EncodedCommand',$taskEncoded) -WorkingDirectory $taskParent -WindowStyle Hidden | Out-Null
    exit 0
} catch {
    if ($taskStage -and (Test-Path -LiteralPath $taskStage)) {
        foreach ($taskName in @('Reset-LightClipUniversal.ps1','Configure-LightClipFirewall.ps1','LightClipServiceSecurity.ps1')) { Remove-Item -LiteralPath (Join-Path $taskStage $taskName) -Force -ErrorAction SilentlyContinue }
        Remove-Item -LiteralPath $taskStage -Force -ErrorAction SilentlyContinue
    }
    Write-Host ('无法启动卸载：' + $_.Exception.Message)
    Read-Host '按回车关闭'
    exit 1
}