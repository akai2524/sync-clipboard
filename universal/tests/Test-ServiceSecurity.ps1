$ErrorActionPreference = 'Stop'
. (Join-Path (Split-Path -Parent $PSScriptRoot) 'tools\LightClipServiceSecurity.ps1')

function Get-DescriptorBytes([string]$Text) {
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Text)
    $bytes = [byte[]]::new($descriptor.BinaryLength)
    $descriptor.GetBinaryForm($bytes, 0)
    return ,$bytes
}

$original = Get-DescriptorBytes 'D:(D;;0x22;;;WD)(D;;0x22;;;SY)(A;;0xF01FF;;;BA)'
$identity = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
$temporary = Get-StopEnabledDescriptor $original $identity
$descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($temporary, 0)
$world = @($descriptor.DiscretionaryAcl | Where-Object { $_.AceQualifier -eq 'AccessDenied' -and $_.SecurityIdentifier.Value -eq 'S-1-1-0' })
$system = @($descriptor.DiscretionaryAcl | Where-Object { $_.AceQualifier -eq 'AccessDenied' -and $_.SecurityIdentifier.Value -eq 'S-1-5-18' })
$allow = @($descriptor.DiscretionaryAcl | Where-Object { $_.AceQualifier -eq 'AccessAllowed' -and $_.SecurityIdentifier.Value -eq $identity -and ($_.AccessMask -band 32) -eq 32 })
if ($world.Count -ne 1 -or $world[0].AccessMask -ne 2 -or $system.Count -ne 1 -or $system[0].AccessMask -ne 34 -or $allow.Count -ne 1) { throw '临时权限范围验证失败。' }
$unexpected = Get-DescriptorBytes 'D:(A;;0xF01FF;;;BA)'
$rejected = $false
try { Get-StopEnabledDescriptor $unexpected $identity | Out-Null } catch { $rejected = $true }
if (-not $rejected) { throw '无法识别的服务权限未被拒绝。' }

$snapshot = Join-Path ([IO.Path]::GetTempPath()) ('LightClip-security-test-' + [Guid]::NewGuid().ToString('N') + '.bin')
try {
    $state = @{ Bytes=$original; Calls=0 }
    $set = { param([byte[]]$value) $state.Bytes=$value; $state.Calls++ }
    $read = { return ,$state.Bytes }
    $fail = { throw '模拟停止服务失败' }
    $failed = $false
    try { Invoke-TemporaryServiceDacl $snapshot $original $temporary $set $read $fail } catch { $failed = $true }
    if (-not $failed -or (Test-Path -LiteralPath $snapshot) -or (Get-DaclText $state.Bytes) -ne (Get-DaclText $original) -or $state.Calls -ne 2) { throw '停止失败后未恢复原权限。' }

    $state = @{ Bytes=$original; Calls=0 }
    $set = { param([byte[]]$value) $state.Calls++; if ($state.Calls -eq 2) { throw '模拟恢复失败' }; $state.Bytes=$value }
    $failed = $false
    try { Invoke-TemporaryServiceDacl $snapshot $original $temporary $set $read $fail } catch { $failed = $true }
    if (-not $failed -or -not (Test-Path -LiteralPath $snapshot) -or (Get-DaclText ([IO.File]::ReadAllBytes($snapshot))) -ne (Get-DaclText $original)) { throw '恢复失败时未保留恢复记录。' }
} finally {
    if (Test-Path -LiteralPath $snapshot -PathType Leaf) { Remove-Item -LiteralPath $snapshot -Force }
}

Write-Output '服务权限测试通过：范围限制、未知权限拒绝、失败恢复和恢复记录保留。未修改任何服务。'
