param([switch]$SelfTest)

$ErrorActionPreference = 'Stop'

function New-Counts {
    return [ordered]@{
        '读取到截图' = 0
        '截图写入缓存' = 0
        '发布剪贴板内容' = 0
        '手机请求图片' = 0
        '开始发送图片' = 0
        '缓存或文件错误' = 0
        '网络通道错误' = 0
        '剪贴板发布错误' = 0
    }
}

function Count-Line($Counts, [string]$Line) {
    if ($Line -match 'ClipboardReader::ReadItems: read bitmap image') { $Counts['读取到截图']++ }
    if ($Line -match 'saved bitmap to') { $Counts['截图写入缓存']++ }
    if ($Line -match 'publishing sequenceId=|Publish: seq=') { $Counts['发布剪贴板内容']++ }
    if ($Line -match 'DataExchangeServer::HandleRequestFileInfo|DataExchangeServer::HandleRequestFileContent') { $Counts['手机请求图片']++ }
    if ($Line -match 'file send progress|sending file ') { $Counts['开始发送图片']++ }
    if ($Line -match 'Local clipboard session or item not found|Local session manager is not available|Local file path is empty|failed to create temp file|failed to open file|failed to create file packet') { $Counts['缓存或文件错误']++ }
    if ($Line -match 'Channel create failed|Channel creation failed|CreateChannel failed|Timeout waiting for channel|RegisterChannelListener failed') { $Counts['网络通道错误']++ }
    if ($Line -match 'Publish failed|encode failed for sequenceId|clipboard access probe failed') { $Counts['剪贴板发布错误']++ }
}

if ($SelfTest) {
    $counts = New-Counts
    @('ClipboardReader::ReadItems: read bitmap image', 'saved bitmap to PRIVATE_PATH',
      'DataExchangeServer::HandleRequestFileContent', 'Local clipboard session or item not found',
      'Channel create failed: device_id=PRIVATE_ID', 'Publish failed') | ForEach-Object { Count-Line $counts $_ }
    foreach ($key in @('读取到截图','截图写入缓存','手机请求图片','缓存或文件错误','网络通道错误','剪贴板发布错误')) {
        if ($counts[$key] -ne 1) { throw '诊断分类自检失败。' }
    }
    if ($counts['发布剪贴板内容'] -ne 0 -or $counts['开始发送图片'] -ne 0) { throw '诊断分类自检失败。' }
    Write-Output '诊断分类自检通过，未读取用户日志。'
    exit 0
}

try {
    $logRoot = Join-Path $env:ProgramData 'MI\DistClipboard\Log'
    if (-not (Test-Path -LiteralPath $logRoot -PathType Container)) { throw '没有找到小米剪贴板日志目录。' }
    $originalLengths = @{}
    foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -File -Recurse -ErrorAction Stop)) {
        $originalLengths[$file.FullName] = $file.Length
    }
    Write-Host '诊断已开始。请保持轻剪运行，在电脑重新截图，然后到手机便签粘贴并等待结果。'
    Read-Host '完成后回到此窗口按回车，生成不含原始日志的统计' | Out-Null

    $counts = New-Counts
    $filesRead = 0; $filesSkipped = 0; $partial = $false; $newBytes = [long]0
    foreach ($file in @(Get-ChildItem -LiteralPath $logRoot -File -Recurse -ErrorAction Stop)) {
        $offset = [long]0
        if ($originalLengths.ContainsKey($file.FullName)) { $offset = [long]$originalLengths[$file.FullName] }
        if ($file.Length -lt $offset) { $offset = 0; $partial = $true }
        if ($file.Length -le $offset) { continue }
        $filesRead++
        if ($filesRead -gt 40) { $partial = $true; break }
        $stream = $null; $reader = $null
        try {
            $stream = [IO.File]::Open($file.FullName, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete)
            if ($stream.Length -lt $offset) { $offset = 0; $partial = $true }
            if (($stream.Length - $offset) -gt 4MB) { $offset = $stream.Length - 4MB; $partial = $true }
            $newBytes += $stream.Length - $offset
            [void]$stream.Seek($offset, [IO.SeekOrigin]::Begin)
            $reader = New-Object IO.StreamReader($stream, [Text.Encoding]::UTF8, $false)
            while (($line = $reader.ReadLine()) -ne $null) { Count-Line $counts $line }
        } catch { $filesSkipped++ }
        finally { if ($null -ne $reader) { $reader.Dispose() } elseif ($null -ne $stream) { $stream.Dispose() } }
    }
    Write-Host ''
    Write-Host '以下仅是本次测试新增日志的类别统计，不包含原始日志：'
    Write-Host ('有新增记录的文件数：' + $filesRead)
    Write-Host ('新增记录字节数：' + $newBytes)
    Write-Host ('无法读取的文件数：' + $filesSkipped)
    Write-Host ('记录可能不完整：' + $partial)
    foreach ($key in $counts.Keys) { Write-Host ($key + '：' + $counts[$key]) }
    Write-Host '统计为 0 不证明该阶段未发生，日志级别或文件轮转可能影响结果。'
} catch {
    Write-Host '无法读取诊断日志，请确认目录存在且当前用户有读取权限。'
}
Read-Host '按回车关闭' | Out-Null
