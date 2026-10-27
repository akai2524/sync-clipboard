param([string]$OutputPath)
$ErrorActionPreference = 'Stop'
$taskNames = @('SyncClipboardLite','XiaomiPcManager','PcClipboard','MiPCAudio','MiSmartShareHandoff','DistributedService','dist_service','handoff_svc','MAFSvr','micont_service','MiPlayCastService')
$taskProcesses = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in $taskNames })
$taskRootIds = @($taskProcesses | Where-Object { $_.ProcessName -in 'SyncClipboardLite','XiaomiPcManager' } | ForEach-Object Id)
$taskAll = @(Get-CimInstance Win32_Process | Select-Object ProcessId,ParentProcessId)
$taskKnownIds = [Collections.Generic.HashSet[int]]::new()
foreach ($taskId in $taskRootIds) { [void]$taskKnownIds.Add($taskId) }
do {
    $taskAdded = $false
    foreach ($taskItem in $taskAll) {
        if ($taskKnownIds.Contains([int]$taskItem.ParentProcessId) -and $taskKnownIds.Add([int]$taskItem.ProcessId)) { $taskAdded = $true }
    }
} while ($taskAdded)
$taskRows = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -in $taskNames -or $taskKnownIds.Contains($_.Id) } | ForEach-Object {
    [pscustomobject]@{
        Name = $_.ProcessName
        Pid = $_.Id
        WorkingSetMB = [math]::Round($_.WorkingSet64 / 1MB, 1)
        PrivateMB = [math]::Round($_.PrivateMemorySize64 / 1MB, 1)
        CpuSeconds = if ($null -eq $_.CPU) { $null } else { [math]::Round($_.CPU, 2) }
    }
})
$taskResult = [pscustomobject]@{
    CapturedAt = (Get-Date).ToString('o')
    Processes = $taskRows
    SumWorkingSetMB = [math]::Round(($taskRows | Measure-Object -Property WorkingSetMB -Sum).Sum, 1)
    SumPrivateMB = [math]::Round(($taskRows | Measure-Object -Property PrivateMB -Sum).Sum, 1)
    Note = '工作集相加可能重复计算共享页面，不能视为独占物理内存。服务包含保留运行的原有小米服务。'
}
if ($OutputPath) { $taskResult | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $OutputPath -Encoding UTF8 }
$taskRows | Format-Table -AutoSize
Write-Output ('工作集合计：{0} MB；私有提交合计：{1} MB' -f $taskResult.SumWorkingSetMB,$taskResult.SumPrivateMB)
Write-Output $taskResult.Note
