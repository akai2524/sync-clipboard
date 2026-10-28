$ErrorActionPreference = 'Stop'
try {
    $base = 'E:\'
    $items = @(Get-ChildItem -LiteralPath $base -Directory -Force | Where-Object {
        $_.Name -eq 'LightClipUniversal' -or $_.Name -match '^LightClipUniversal-cleanup-[0-9a-f]{32}$'
    })
    Write-Host ('找到轻剪目录数量：' + $items.Count)
    foreach ($item in $items) {
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Write-Host ('跳过重解析点：' + $item.Name); continue }
        Write-Host ('目录：' + $item.FullName)
        $dll = Join-Path $item.FullName 'x86\AIotExService.dll'
        if (Test-Path -LiteralPath $dll -PathType Leaf) {
            $file = Get-Item -LiteralPath $dll -Force
            if (($file.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { Write-Host '目标 DLL 是重解析点，已跳过。'; continue }
            Write-Host ('目标 DLL 存在，属性：' + $file.Attributes)
            try {
                $handle = [IO.File]::Open($dll, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
                $handle.Dispose()
                Write-Host '目标 DLL 独占读取：成功'
            } catch {
                $ex = $_.Exception
                while ($ex.InnerException) { $ex = $ex.InnerException }
                Write-Host ('目标 DLL 独占读取失败：异常类型=' + $ex.GetType().Name + '，系统码=' + ($ex.HResult -band 0xffff))
            }
        } else { Write-Host '目标 DLL：不存在' }
        $matched = 0; $denied = 0
        foreach ($process in @(Get-Process)) {
            try {
                foreach ($module in @($process.Modules)) {
                    if ([String]::Equals($module.FileName, $dll, [StringComparison]::OrdinalIgnoreCase)) {
                        Write-Host ('使用目标 DLL 的进程：' + $process.ProcessName + '，PID=' + $process.Id)
                        $matched++; break
                    }
                }
            } catch { $denied++ }
        }
        Write-Host ('发现使用目标 DLL 的进程数量：' + $matched + '；无法检查模块的进程数量：' + $denied)
    }
    foreach ($name in @('MiPcContinuityService','micont_service')) {
        $service = Get-CimInstance -ClassName Win32_Service -Filter ("Name='" + $name + "'") -ErrorAction Stop
        if ($service) { Write-Host ('服务 ' + $name + '：状态=' + $service.State + '，PID=' + $service.ProcessId + '，路径=' + $service.PathName) }
        else { Write-Host ('服务 ' + $name + '：未找到') }
    }
    Write-Host '检查完成；本工具没有停止服务、修改权限或删除文件。'
} catch { Write-Host ('检查未完成：' + $_.Exception.Message) }
Read-Host '按回车关闭' | Out-Null
