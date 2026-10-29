[CmdletBinding()]
param(
    [string]$CodexPath,
    [string]$CodexHome = $(if ($env:CODEX_HOME) { $env:CODEX_HOME } else { Join-Path $env:USERPROFILE '.codex' }),
    [switch]$CheckOnly
)

$ErrorActionPreference = 'Stop'

function Get-RespectSystemProxyState {
    param([string]$Content)

    $inFeatures = $false
    foreach ($line in [Regex]::Split($Content, '\r?\n')) {
        if ($line -match '^[ \t]*\[([^\]]+)\][ \t]*(?:#.*)?$') {
            $inFeatures = ($Matches[1] -eq 'features')
            continue
        }
        if ($inFeatures -and $line -match '^[ \t]*respect_system_proxy[ \t]*=[ \t]*(true|false)[ \t]*(?:#.*)?$') {
            if ($Matches[1] -eq 'true') { return 'Enabled' }
            return 'Disabled'
        }
    }
    return 'Missing'
}

function Set-RespectSystemProxyEnabled {
    param([string]$Content)

    $newline = if ($Content.Contains("`r`n")) { "`r`n" } else { "`n" }
    $lines = New-Object 'System.Collections.Generic.List[string]'
    [Regex]::Split($Content, '\r?\n') | ForEach-Object { $lines.Add($_) }

    $featuresIndex = -1
    $nextSectionIndex = $lines.Count
    for ($i = 0; $i -lt $lines.Count; $i++) {
        if ($lines[$i] -match '^[ \t]*\[([^\]]+)\][ \t]*(?:#.*)?$') {
            if ($featuresIndex -ge 0) {
                $nextSectionIndex = $i
                break
            }
            if ($Matches[1] -eq 'features') { $featuresIndex = $i }
        }
    }

    if ($featuresIndex -ge 0) {
        for ($i = $featuresIndex + 1; $i -lt $nextSectionIndex; $i++) {
            if ($lines[$i] -match '^[ \t]*respect_system_proxy[ \t]*=') {
                $lines[$i] = [Regex]::Replace(
                    $lines[$i],
                    '^([ \t]*respect_system_proxy[ \t]*=[ \t]*)(?:true|false)(.*)$',
                    '${1}true${2}'
                )
                return [string]::Join($newline, $lines)
            }
        }
        $lines.Insert($featuresIndex + 1, 'respect_system_proxy = true')
        return [string]::Join($newline, $lines)
    }

    if ([string]::IsNullOrEmpty($Content)) {
        return '[features]' + $newline + 'respect_system_proxy = true' + $newline
    }

    $separator = if ($Content.EndsWith("`n")) { $newline } else { $newline + $newline }
    return $Content + $separator + '[features]' + $newline + 'respect_system_proxy = true' + $newline
}

function Enable-CodexSystemProxy {
    param([string]$HomePath, [switch]$OnlyCheck)

    $configPath = Join-Path $HomePath 'config.toml'
    $exists = Test-Path -LiteralPath $configPath
    $content = if ($exists) { [IO.File]::ReadAllText($configPath) } else { '' }
    $state = Get-RespectSystemProxyState $content

    if ($state -eq 'Enabled') {
        return [pscustomobject]@{ Success = $true; Reason = 'AlreadyEnabled'; Changed = $false; BackupPath = $null }
    }
    if ($OnlyCheck) {
        return [pscustomobject]@{ Success = $true; Reason = 'NotEnabled'; Changed = $false; BackupPath = $null }
    }

    New-Item -ItemType Directory -Force -Path $HomePath | Out-Null
    $backupPath = $null
    if ($exists) {
        $backupRoot = Join-Path $HomePath 'backups\codex-system-proxy'
        New-Item -ItemType Directory -Force -Path $backupRoot | Out-Null
        $backupPath = Join-Path $backupRoot ('config-' + (Get-Date -Format 'yyyyMMdd-HHmmss-fff') + '.toml')
        Copy-Item -LiteralPath $configPath -Destination $backupPath
    }

    $withBom = $false
    if ($exists) {
        $bytes = [IO.File]::ReadAllBytes($configPath)
        $withBom = $bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF
    }
    $updated = Set-RespectSystemProxyEnabled $content
    $temporaryPath = $configPath + '.tmp-' + [Guid]::NewGuid().ToString('N')
    try {
        [IO.File]::WriteAllText($temporaryPath, $updated, (New-Object Text.UTF8Encoding($withBom)))
        Move-Item -LiteralPath $temporaryPath -Destination $configPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryPath) { Remove-Item -LiteralPath $temporaryPath -Force }
    }

    $verified = Get-RespectSystemProxyState ([IO.File]::ReadAllText($configPath))
    [pscustomobject]@{
        Success = ($verified -eq 'Enabled')
        Reason = if ($verified -eq 'Enabled') { 'Enabled' } else { 'VerificationFailed' }
        Changed = ($verified -eq 'Enabled')
        BackupPath = $backupPath
    }
}

function Get-SystemProxyStatus {
    try {
        $settings = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'
        if ([int]$settings.ProxyEnable -ne 1 -or [string]::IsNullOrWhiteSpace($settings.ProxyServer)) {
            return [pscustomobject]@{ Enabled = $false; LocalPortReachable = $false }
        }

        $candidate = @($settings.ProxyServer -split ';' | Where-Object { $_ -match '^(?:https=)?(?:https?://)?(?:127\.0\.0\.1|localhost):\d+$' } | Select-Object -First 1)
        if ($candidate.Count -eq 0) {
            return [pscustomobject]@{ Enabled = $true; LocalPortReachable = $false }
        }
        $port = [int]([Regex]::Match($candidate[0], ':(\d+)$').Groups[1].Value)
        $client = New-Object Net.Sockets.TcpClient
        try {
            $task = $client.ConnectAsync('127.0.0.1', $port)
            $reachable = $task.Wait(1200) -and $client.Connected
        }
        catch { $reachable = $false }
        finally { $client.Dispose() }
        [pscustomobject]@{ Enabled = $true; LocalPortReachable = $reachable }
    }
    catch {
        [pscustomobject]@{ Enabled = $false; LocalPortReachable = $false }
    }
}

Write-Host '=== Codex 系统代理一键启用工具 ===' -ForegroundColor Cyan
$result = Enable-CodexSystemProxy $CodexHome -OnlyCheck:$CheckOnly
if (-not $result.Success) {
    Write-Host ('启用失败：' + $result.Reason) -ForegroundColor Red
    if ($result.BackupPath) { Write-Host ('配置备份：' + $result.BackupPath) }
    exit 3
}

switch ($result.Reason) {
    'AlreadyEnabled' { Write-Host '该功能已经启用，无需重复修改。' -ForegroundColor Green }
    'NotEnabled' { Write-Host '检查完成：该功能尚未启用。' -ForegroundColor Yellow }
    'Enabled' {
        Write-Host '启用并验证成功。' -ForegroundColor Green
        if ($result.BackupPath) { Write-Host ('原配置备份：' + $result.BackupPath) }
    }
}

$proxy = Get-SystemProxyStatus
if (-not $proxy.Enabled) {
    Write-Host '提醒：Windows 系统代理当前未开启；请先在 SuYou/Clash 中打开“系统代理”。' -ForegroundColor Yellow
}
elseif (-not $proxy.LocalPortReachable) {
    Write-Host '提醒：系统代理已配置，但本地代理端口目前无法连接；请确认代理软件正在运行。' -ForegroundColor Yellow
}
else {
    Write-Host 'Windows 系统代理检查正常。' -ForegroundColor Green
}

if (-not $CheckOnly) {
    Write-Host ''
    Write-Host '本工具没有关闭任何程序。请从系统托盘完全退出 ChatGPT，再重新打开；预计中断 10–20 秒。' -ForegroundColor Cyan
}
exit 0
