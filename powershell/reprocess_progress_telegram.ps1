param(
    [string]$RemoteUser = "root",
    [string]$RemoteHost = "192.168.100.89",
    [string]$WorkRoot = "C:\temp\nas-reprocess-heavy",
    [int]$IntervalMinutes = 10
)

$ErrorActionPreference = "Stop"

function Get-ReprocessWorkers {
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "pwsh.exe" -and
            $_.CommandLine -match "reprocess_heavy_from_server.ps1" -and
            $_.ParentProcessId -ne $PID
        }
}

function Get-ProgressSummary {
    param([string]$Root)

    $dirs = Get-ChildItem -Path $Root -Directory -ErrorAction SilentlyContinue
    $done = 0
    $total = 0
    $parts = @()
    foreach ($d in $dirs) {
        $log = Get-ChildItem -Path $d.FullName -Filter "reprocess-heavy-*.log" -ErrorAction SilentlyContinue |
            Sort-Object LastWriteTime -Descending |
            Select-Object -First 1
        if (-not $log) { continue }
        $last = Select-String -Path $log.FullName -Pattern "\[(\d+)/(\d+)\]" | Select-Object -Last 1
        if (-not $last) { continue }
        $m = $last.Matches[0]
        $dCount = [int]$m.Groups[1].Value
        $tCount = [int]$m.Groups[2].Value
        $done += $dCount
        $total += $tCount
        $parts += ("{0} {1}/{2}" -f $d.Name, $dCount, $tCount)
    }

    $left = if ($total -gt 0) { $total - $done } else { 0 }
    [PSCustomObject]@{
        Done   = $done
        Total  = $total
        Left   = $left
        Detail = ($parts -join ", ")
    }
}

function Send-Telegram {
    param([string]$Text)
    $safe = $Text.Replace("'", "''")
    & ssh "$RemoteUser@$RemoteHost" "/usr/local/bin/nas-alert.sh '$safe'" | Out-Null
}

if ($IntervalMinutes -lt 1) { $IntervalMinutes = 1 }
$intervalSec = $IntervalMinutes * 60

while ($true) {
    $workers = Get-ReprocessWorkers
    if (-not $workers -or $workers.Count -eq 0) {
        $endSummary = Get-ProgressSummary -Root $WorkRoot
        $final = @"
✅ Reproceso GPU terminado
Avance final: $($endSummary.Done)/$($endSummary.Total)
Faltan: $($endSummary.Left)
Detalle: $($endSummary.Detail)
"@
        Send-Telegram -Text $final
        break
    }

    $s = Get-ProgressSummary -Root $WorkRoot
    $msg = @"
📊 Estatus reproceso GPU (cada $IntervalMinutes min)
Avance: $($s.Done)/$($s.Total)
Faltan: $($s.Left)
Detalle: $($s.Detail)
"@
    Send-Telegram -Text $msg
    Start-Sleep -Seconds $intervalSec
}

