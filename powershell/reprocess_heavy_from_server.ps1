param(
    [string]$RemoteUser = "root",
    [string]$RemoteHost = "192.168.100.89",
    [string]$RemotePlanCmd = "python3 /usr/local/bin/video-reprocess-manager.py plan --output-dir /var/lib/nas-health/reprocess",
    [string]$RemoteHeavyCsv = "/var/lib/nas-health/reprocess/heavy-latest.csv",
    [string]$LocalWork = "C:\temp\nas-reprocess-heavy",
    [double]$TargetMbPerMin = 38,
    [int]$AudioKbps = 128,
    [int]$Limit = 0,
    [switch]$PlanOnly,
    [switch]$NoPlan,
    [switch]$NoNvenc,
    [switch]$ForceReencode
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (!(Test-Path $LocalWork)) {
    New-Item -ItemType Directory -Force -Path $LocalWork | Out-Null
}

Get-ChildItem -Path $LocalWork -File -Include "in_*.bin","out_*.mp4" -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue

$runId = (Get-Date).ToString("yyyyMMdd_HHmmss")
$logFile = Join-Path $LocalWork "reprocess-heavy-$runId.log"
$csvLocal = Join-Path $LocalWork "heavy-latest-$runId.csv"
$reportFile = Join-Path $LocalWork "reprocess-heavy-report-$runId.csv"

function Log {
    param([string]$Msg, [string]$Color = "Cyan")
    $line = "[$((Get-Date).ToString('HH:mm:ss'))] $Msg"
    Write-Host $line -ForegroundColor $Color
    Add-Content -Path $logFile -Value $line
}

function Invoke-External {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [Parameter(Mandatory = $true)][string[]]$ArgumentList,
        [int]$TimeoutSec = 7200,
        [string]$Label = "cmd"
    )
    $prevEa = $global:ErrorActionPreference
    $global:ErrorActionPreference = "Continue"
    try {
        $all = & $FilePath @ArgumentList 2>&1
    }
    finally {
        $global:ErrorActionPreference = $prevEa
    }
    $code = $LASTEXITCODE
    $text = if ($all) { ($all | Out-String) } else { "" }
    return [PSCustomObject]@{
        ExitCode = $code
        StdOut   = $text
        StdErr   = $text
    }
}

function Quote-Sq {
    param([string]$Value)
    # Las rutas esperadas en Immich no incluyen comillas simples.
    return "'" + $Value + "'"
}

function Get-RemoteDir {
    param([string]$PathUnix)
    $i = $PathUnix.LastIndexOf("/")
    if ($i -le 0) { return "/" }
    return $PathUnix.Substring(0, $i)
}

function Safe-Text {
    param([object]$Value)
    return ([string]$Value).Trim()
}

$sshOpts = @(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=20",
    "-o", "ServerAliveInterval=20",
    "-o", "ServerAliveCountMax=3"
)

Log "RUN: $runId"
Log "Host: $RemoteUser@$RemoteHost"

if (-not $NoPlan) {
    Log "Generando insumos en el server..."
    $rPlan = Invoke-External -FilePath "ssh" -ArgumentList ($sshOpts + @("${RemoteUser}@${RemoteHost}", $RemotePlanCmd)) -TimeoutSec 1800 -Label "ssh-plan"
    if ($rPlan.ExitCode -ne 0) {
        Log "Plan por helper fallo (exit=$($rPlan.ExitCode)). Intento fallback..." "DarkYellow"
        $fallbackOut = & ssh @sshOpts "${RemoteUser}@${RemoteHost}" $RemotePlanCmd 2>&1
        if ($LASTEXITCODE -ne 0) {
            Log "No pude generar plan en server: $(Safe-Text $rPlan.StdErr)" "Red"
            throw "Plan remoto fallo"
        }
        if ($fallbackOut) {
            Log "Plan remoto OK (fallback)."
        }
    }
    if ($rPlan.StdOut) {
        Log "Plan remoto OK"
    }
}

Log "Descargando insumo heavy: $RemoteHeavyCsv"
$rCsv = Invoke-External -FilePath "scp" -ArgumentList (@("-q") + $sshOpts + @("${RemoteUser}@${RemoteHost}:$RemoteHeavyCsv", $csvLocal)) -TimeoutSec 1800 -Label "scp-heavy-csv"
if ($rCsv.ExitCode -ne 0 -or -not (Test-Path $csvLocal)) {
    Log "No pude descargar CSV heavy: $(Safe-Text $rCsv.StdErr)" "Red"
    throw "CSV heavy no disponible"
}

$rows = Import-Csv -Path $csvLocal
$total = $rows.Count
Log "Heavy candidates en CSV: $total"

if ($PlanOnly) {
    Log "PlanOnly activo: no se inicia conversión."
    return
}

$encoders = (& ffmpeg -hide_banner -encoders 2>$null | Out-String)
$hasNvenc = (-not $NoNvenc) -and ($encoders -match "h264_nvenc")
$targetTotalKbps = [math]::Round(($TargetMbPerMin * 8000) / 60)
$targetVideoKbps = [math]::Max(700, ($targetTotalKbps - $AudioKbps))
$scaleFilter = "scale=1920:1920:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"

Log "Encoder: $(if($hasNvenc){'h264_nvenc'}else{'libx264'})"
Log "Target: $TargetMbPerMin MB/min (~${targetVideoKbps}k video + ${AudioKbps}k audio)"
Log "Modo force-reencode: $(if($ForceReencode){'ON'}else{'OFF'})"

$report = New-Object System.Collections.Generic.List[object]
$countOk = 0
$countSkip = 0
$countFail = 0
$index = 0
$createdDirs = New-Object 'System.Collections.Generic.HashSet[string]'

foreach ($row in $rows) {
    if ($Limit -gt 0 -and $index -ge $Limit) { break }
    $index++

    $asset = ($row.asset_id | Out-String).Trim()
    $src = ($row.source_path | Out-String).Trim()
    $dst = ($row.dest_cache_path | Out-String).Trim()

    if ([string]::IsNullOrWhiteSpace($asset) -or [string]::IsNullOrWhiteSpace($src) -or [string]::IsNullOrWhiteSpace($dst)) {
        $countFail++
        $report.Add([PSCustomObject]@{asset_id=$asset;status="bad_row";source_path=$src;dest_cache_path=$dst;note="missing columns"})
        continue
    }

    Log "[$index/$total] $asset" "DarkCyan"

    $qDst = Quote-Sq $dst
    $qSrc = Quote-Sq $src
    if (-not $ForceReencode) {
        $rExists = Invoke-External -FilePath "ssh" -ArgumentList ($sshOpts + @("${RemoteUser}@${RemoteHost}", "if [ -s $qDst ]; then echo 1; fi")) -TimeoutSec 60 -Label "ssh-dst-exists"
        if ($rExists.ExitCode -eq 0 -and $rExists.StdOut -match "1") {
            $countSkip++
            $report.Add([PSCustomObject]@{asset_id=$asset;status="skip_already_cached";source_path=$src;dest_cache_path=$dst;note=""})
            continue
        }
    }

    $localIn = Join-Path $LocalWork ("in_" + $asset + ".bin")
    $localOut = Join-Path $LocalWork ("out_" + $asset + ".mp4")
    Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue

    $rDl = Invoke-External -FilePath "scp" -ArgumentList (@("-q") + $sshOpts + @("${RemoteUser}@${RemoteHost}:$src", $localIn)) -TimeoutSec 7200 -Label "scp-download"
    if ($rDl.ExitCode -ne 0 -or -not (Test-Path $localIn)) {
        $countFail++
        $report.Add([PSCustomObject]@{asset_id=$asset;status="download_failed";source_path=$src;dest_cache_path=$dst;note=(Safe-Text $rDl.StdErr)})
        continue
    }

    if ($hasNvenc) {
        $ffArgs = @(
            "-y", "-hwaccel", "cuda", "-i", $localIn,
            "-c:v", "h264_nvenc", "-preset", "p4", "-rc", "vbr",
            "-b:v", "${targetVideoKbps}k", "-maxrate", "${targetVideoKbps}k", "-bufsize", "$($targetVideoKbps * 2)k",
            "-vf", $scaleFilter,
            "-profile:v", "high", "-level:v", "4.1", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "${AudioKbps}k", "-movflags", "+faststart", $localOut
        )
    }
    else {
        $ffArgs = @(
            "-y", "-i", $localIn,
            "-c:v", "libx264", "-preset", "veryfast",
            "-b:v", "${targetVideoKbps}k", "-maxrate", "${targetVideoKbps}k", "-bufsize", "$($targetVideoKbps * 2)k",
            "-vf", $scaleFilter,
            "-profile:v", "high", "-level:v", "4.1", "-pix_fmt", "yuv420p",
            "-c:a", "aac", "-b:a", "${AudioKbps}k", "-movflags", "+faststart", $localOut
        )
    }

    $rEnc = Invoke-External -FilePath "ffmpeg" -ArgumentList $ffArgs -TimeoutSec 7200 -Label "ffmpeg-encode"
    if ($rEnc.ExitCode -ne 0 -or !(Test-Path $localOut) -or ((Get-Item $localOut).Length -le 0)) {
        $countFail++
        $report.Add([PSCustomObject]@{asset_id=$asset;status="ffmpeg_failed";source_path=$src;dest_cache_path=$dst;note=(Safe-Text $rEnc.StdErr)})
        Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
        continue
    }

    $remoteDir = Get-RemoteDir -PathUnix $dst
    $tmpRemote = "$dst.tmp.pc.mp4"
    $qDir = Quote-Sq $remoteDir
    $qTmp = Quote-Sq $tmpRemote
    if (-not $createdDirs.Contains($remoteDir)) {
        $rMk = Invoke-External -FilePath "ssh" -ArgumentList ($sshOpts + @("${RemoteUser}@${RemoteHost}", "mkdir -p $qDir")) -TimeoutSec 60 -Label "ssh-mkdir"
        if ($rMk.ExitCode -ne 0) {
            $countFail++
            $report.Add([PSCustomObject]@{asset_id=$asset;status="mkdir_failed";source_path=$src;dest_cache_path=$dst;note=(Safe-Text $rMk.StdErr)})
            Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
            continue
        }
        [void]$createdDirs.Add($remoteDir)
    }

    $rUl = Invoke-External -FilePath "scp" -ArgumentList (@("-q") + $sshOpts + @($localOut, "${RemoteUser}@${RemoteHost}:$tmpRemote")) -TimeoutSec 7200 -Label "scp-upload"
    if ($rUl.ExitCode -ne 0) {
        $countFail++
        $report.Add([PSCustomObject]@{asset_id=$asset;status="upload_failed";source_path=$src;dest_cache_path=$dst;note=(Safe-Text $rUl.StdErr)})
        Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
        continue
    }

    $rMv = Invoke-External -FilePath "ssh" -ArgumentList ($sshOpts + @("${RemoteUser}@${RemoteHost}", "mv -f $qTmp $qDst")) -TimeoutSec 60 -Label "ssh-move"
    if ($rMv.ExitCode -ne 0) {
        $countFail++
        $report.Add([PSCustomObject]@{asset_id=$asset;status="remote_move_failed";source_path=$src;dest_cache_path=$dst;note=(Safe-Text $rMv.StdErr)})
        Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
        continue
    }

    $countOk++
    $report.Add([PSCustomObject]@{asset_id=$asset;status="ok";source_path=$src;dest_cache_path=$dst;note=""})
    Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
}

$report | Export-Csv -Path $reportFile -NoTypeInformation -Encoding UTF8
Log "Finalizado. OK=$countOk | SKIP=$countSkip | FAIL=$countFail" "Yellow"
Log "Reporte: $reportFile" "Yellow"
