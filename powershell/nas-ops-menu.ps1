param(
    [string]$ConfigPath = (Join-Path $PSScriptRoot "nas-ops.config.ps1")
)

$ErrorActionPreference = "Stop"
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

if (!(Test-Path $ConfigPath)) {
    throw "No existe config: $ConfigPath"
}

$cfg = . $ConfigPath
if ($null -eq $cfg -or -not ($cfg -is [hashtable])) {
    throw "El archivo de config debe devolver un hashtable."
}

$server = "$($cfg.ServerUser)@$($cfg.ServerHost)"
$sshCommon = @(
    "-o", "BatchMode=yes",
    "-o", "StrictHostKeyChecking=no",
    "-o", "ConnectTimeout=$($cfg.ConnectTimeoutSec)"
)

function Write-Info {
    param([string]$Text, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    $ts = (Get-Date).ToString("HH:mm:ss")
    Write-Host "[$ts] $Text" -ForegroundColor $Color
}

function Invoke-Ssh {
    param(
        [Parameter(Mandatory = $true)][string]$RemoteCommand,
        [switch]$Quiet
    )

    $args = $sshCommon + @($server, $RemoteCommand)
    $out = & $cfg.SshExe @args 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $Quiet) {
        Write-Host ($out | Out-String) -ForegroundColor Red
        throw "Fallo comando SSH (exit=$code)"
    }
    return [PSCustomObject]@{
        ExitCode = $code
        Output   = ($out | Out-String)
    }
}

function Invoke-Wsl {
    param(
        [Parameter(Mandatory = $true)][string]$Command,
        [switch]$Quiet
    )

    $wslExe = if ($cfg.ContainsKey("WslExe") -and $cfg.WslExe) { $cfg.WslExe } else { "wsl" }
    $out = & $wslExe -e sh -lc $Command 2>&1
    $code = $LASTEXITCODE
    if ($code -ne 0 -and -not $Quiet) {
        Write-Host ($out | Out-String) -ForegroundColor Yellow
    }
    return [PSCustomObject]@{
        ExitCode = $code
        Output   = ($out | Out-String)
    }
}

function Send-StepTelegram {
    param([string]$Message)
    $safe = $Message.Replace('"', '\"')
    Invoke-Ssh "/usr/local/bin/nas-alert.sh `"$safe`"" -Quiet | Out-Null
}

function Show-Overview {
    Write-Info "Levantando resumen del NAS..."
    Invoke-Ssh "date; uptime; free -h; df -h / /var/lib/immich /mnt/storage-main /mnt/storage-backup 2>/dev/null; docker ps --format '{{.Names}}\t{{.Status}}'" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Show-Queues {
    Write-Info "Leyendo colas de Immich..."
    $cmd = @'
python3 - <<'PY'
import json, urllib.request
sec={}
for line in open("/etc/nas-secrets", encoding="utf-8", errors="ignore"):
    line=line.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k,v=line.split("=",1)
    sec[k.strip()]=v.strip().strip('"')
api="http://127.0.0.1:2283/api"
if sec.get("IMMICH_API_KEY"):
    req=urllib.request.Request(api+"/queues", headers={"x-api-key":sec["IMMICH_API_KEY"]})
    data=json.load(urllib.request.urlopen(req, timeout=20))
else:
    body=json.dumps({"email":sec.get("IMMICH_ADMIN_EMAIL",""),"password":sec.get("IMMICH_ADMIN_PASSWORD","")}).encode("utf-8")
    req=urllib.request.Request(api+"/auth/login", data=body, headers={"Content-Type":"application/json"})
    tok=json.load(urllib.request.urlopen(req, timeout=20)).get("accessToken","")
    req=urllib.request.Request(api+"/queues", headers={"Authorization":"Bearer "+tok})
    data=json.load(urllib.request.urlopen(req, timeout=20))
for q in data:
    st=q.get("statistics",{})
    print(f'{q.get("name"):22} paused={q.get("isPaused")} a={st.get("active",0)} w={st.get("waiting",0)} p={st.get("paused",0)}')
PY
'@
    Invoke-Ssh $cmd | ForEach-Object { Write-Host $_.Output }
}

function Run-ImlDrain {
    param([string]$Targets)
    $targetsArg = if ([string]::IsNullOrWhiteSpace($Targets)) { "" } else { "--targets $Targets" }
    $msg = "🔧 Inicio drenado IML manual desde menú PC`nTargets: $Targets"
    Send-StepTelegram $msg
    Write-Info "Ejecutando drenado IML ($Targets)..."
    Invoke-Ssh "python3 /usr/local/bin/iml-backlog-drain.py $targetsArg --sleep-sec 20 --log-every 4 --timeout-min 720" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Run-ImlSingle {
    param(
        [Parameter(Mandatory = $true)][string]$Target,
        [Parameter(Mandatory = $true)][string]$Label
    )
    Write-Info "Drenando cola IML: $Label"
    Run-ImlDrain -Targets $Target
}

function Run-ImlFinalize {
    Send-StepTelegram "🏁 Inicio monitoreo IML hasta cierre final (colas->0 y regreso a normalidad)"
    Write-Info "Corriendo iml-drain-finalize.py (monitorea hasta terminar y cierra túnel)..."
    Invoke-Ssh "python3 /usr/local/bin/iml-drain-finalize.py --timeout-min 720 --sleep-sec 20" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Run-VideoAutopilotOnce {
    Send-StepTelegram "🎬 Ejecución manual de video-autopilot desde menú PC"
    Write-Info "Corriendo video-autopilot..."
    Invoke-Ssh "/usr/local/bin/video-autopilot.sh" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Run-PlaybackAudit {
    Send-StepTelegram "🎥 Ejecución manual playback-audit-autoheal desde menú PC"
    Write-Info "Corriendo playback-audit-autoheal..."
    Invoke-Ssh "/usr/local/bin/playback-audit-autoheal.sh" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Run-StateBackup {
    $includeCache = Read-Host "¿Incluir cache completo? (s/n)"
    $withCache = if ($includeCache -match '^(s|S|y|Y)$') { "INCLUDE_CACHE=1" } else { "INCLUDE_CACHE=0" }
    Send-StepTelegram "🧰 Iniciando backup de estado desde menú PC (cache=$withCache)"
    Write-Info "Corriendo state-backup..."
    Invoke-Ssh "$withCache /usr/local/bin/state-backup.sh" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Run-StateRestore {
    $snap = Read-Host "Snapshot a restaurar (latest o ruta completa)"
    if ([string]::IsNullOrWhiteSpace($snap)) { $snap = "latest" }
    $withDb = Read-Host "¿Restaurar DB? (s/n)"
    $withCache = Read-Host "¿Restaurar cache.tar.gz? (s/n)"
    $dbArg = if ($withDb -match '^(s|S|y|Y)$') { "--with-db" } else { "" }
    $cacheArg = if ($withCache -match '^(s|S|y|Y)$') { "--with-cache" } else { "" }
    Send-StepTelegram "♻️ Restauración iniciada desde menú PC`nSnapshot: $snap`nDB: $dbArg`nCache: $cacheArg"
    Write-Info "Corriendo state-restore..."
    Invoke-Ssh "/usr/local/bin/state-restore.sh `"$snap`" $dbArg $cacheArg" | ForEach-Object {
        Write-Host $_.Output
    }
}

function Show-KeyLogs {
    $cmd = @'
echo "==== night-run.log ===="
tail -n 80 /var/log/night-run.log 2>/dev/null || true
echo "==== video-reprocess-nightly.log ===="
tail -n 80 /var/log/video-reprocess-nightly.log 2>/dev/null || true
echo "==== playback-audit-autoheal.log ===="
tail -n 80 /var/log/playback-audit-autoheal.log 2>/dev/null || true
echo "==== playback-watchdog.log ===="
tail -n 80 /var/log/playback-watchdog.log 2>/dev/null || true
'@
    Invoke-Ssh $cmd | ForEach-Object { Write-Host $_.Output }
}

function Get-MlTunnelLocalSshProcesses {
    $route = "$($cfg.MlTunnelRemoteBind):$($cfg.MlTunnelLocalTarget)"
    $routeEsc = [regex]::Escape($route)
    $hostEsc = [regex]::Escape($cfg.ServerHost)
    Get-CimInstance Win32_Process |
        Where-Object {
            $_.Name -eq "ssh.exe" -and
            $_.CommandLine -match $routeEsc -and
            $_.CommandLine -match $hostEsc
        }
}

function Stop-MlTunnelLocalProcesses {
    param([switch]$Quiet)

    $stopped = New-Object System.Collections.Generic.HashSet[int]

    if (Test-Path $cfg.MlTunnelPidFile) {
        $pidText = Get-Content $cfg.MlTunnelPidFile -ErrorAction SilentlyContinue
        if ($pidText -and ($pidText -match '^\d+$')) {
            try {
                Stop-Process -Id ([int]$pidText) -Force -ErrorAction Stop
                [void]$stopped.Add([int]$pidText)
                if (-not $Quiet) { Write-Info "Túnel detenido por PID file ($pidText)." Green }
            }
            catch {
                if (-not $Quiet) { Write-Info "PID file presente pero proceso no activo: $pidText" Yellow }
            }
        }
        Remove-Item $cfg.MlTunnelPidFile -Force -ErrorAction SilentlyContinue
    }

    foreach ($p in (Get-MlTunnelLocalSshProcesses)) {
        try {
            Stop-Process -Id ([int]$p.ProcessId) -Force -ErrorAction Stop
            [void]$stopped.Add([int]$p.ProcessId)
            if (-not $Quiet) { Write-Info "Detuve ssh túnel huérfano PID=$($p.ProcessId)." Green }
        }
        catch {
            if (-not $Quiet) { Write-Info "No pude detener PID $($p.ProcessId)." Yellow }
        }
    }

    return [PSCustomObject]@{
        StoppedCount = $stopped.Count
        StoppedPids  = @($stopped)
    }
}

function Stop-MlTunnelRemoteSide {
    $cmd = @'
docker stop ml_tunnel_proxy >/dev/null 2>&1 || true
PIDS=$(ss -ltnp 2>/dev/null | grep -E ':13003|:13031' | sed -n 's/.*pid=\([0-9]\+\).*/\1/p' | sort -u || true)
if [ -n "$PIDS" ]; then
  kill -TERM $PIDS >/dev/null 2>&1 || true
  sleep 1
fi
ss -ltnp 2>/dev/null | grep -E ':13003|:13031' || true
'@
    return (Invoke-Ssh $cmd -Quiet)
}

function Ensure-LocalMlServiceRunning {
    $autoStart = if ($cfg.ContainsKey("MlAutoStartLocalService")) { [bool]$cfg.MlAutoStartLocalService } else { $true }
    if (-not $autoStart) { return }

    $container = if ($cfg.ContainsKey("MlLocalDockerContainer")) { [string]$cfg.MlLocalDockerContainer } else { "" }
    if ([string]::IsNullOrWhiteSpace($container)) { return }

    $check = Invoke-Wsl "docker inspect -f '{{.State.Running}}' '$container' 2>/dev/null || echo missing" -Quiet
    $state = ($check.Output.Trim() -split "`r?`n" | Select-Object -First 1).Trim().ToLower()

    if ($state -eq "true") {
        Write-Info "Servicio ML local ya estaba activo ($container)." Green
        return
    }

    Invoke-Wsl "docker start '$container' >/dev/null 2>&1 || true" -Quiet | Out-Null
    $recheck = Invoke-Wsl "docker inspect -f '{{.State.Running}}' '$container' 2>/dev/null || echo missing" -Quiet
    $rstate = ($recheck.Output.Trim() -split "`r?`n" | Select-Object -First 1).Trim().ToLower()
    if ($rstate -eq "true") {
        Write-Info "Servicio ML local iniciado ($container)." Green
    } else {
        Write-Info "No pude confirmar inicio del servicio ML local ($container)." Yellow
    }
}

function Stop-LocalMlService {
    $autoStop = if ($cfg.ContainsKey("MlAutoStopLocalService")) { [bool]$cfg.MlAutoStopLocalService } else { $true }
    if (-not $autoStop) {
        return [PSCustomObject]@{
            StoppedCount = 0
            Remaining    = ""
        }
    }

    $container = if ($cfg.ContainsKey("MlLocalDockerContainer")) { [string]$cfg.MlLocalDockerContainer } else { "" }
    $port = if ($cfg.ContainsKey("MlLocalListenPort")) { [int]$cfg.MlLocalListenPort } else { 3003 }

    if (-not [string]::IsNullOrWhiteSpace($container)) {
        Invoke-Wsl "docker ps --format '{{.Names}}' | grep -Fx '$container' >/dev/null && docker stop '$container' >/dev/null 2>&1 || true" -Quiet | Out-Null
    }

    $remaining = Invoke-Wsl "docker ps --filter publish=$port --format '{{.Names}}'" -Quiet
    $list = @($remaining.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

    if ($list.Count -gt 0) {
        foreach ($name in $list) {
            Invoke-Wsl "docker stop '$name' >/dev/null 2>&1 || true" -Quiet | Out-Null
        }
    }

    $after = Invoke-Wsl "docker ps --filter publish=$port --format '{{.Names}}'" -Quiet
    $afterList = @($after.Output -split "`r?`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

    return [PSCustomObject]@{
        StoppedCount = $list.Count
        Remaining    = ($afterList -join ",")
    }
}

function Start-MlTunnel {
    Ensure-LocalMlServiceRunning

    $existing = Get-MlTunnelLocalSshProcesses
    if ($existing) {
        Write-Info "Encontré túnel previo; limpio primero procesos locales huérfanos..." Yellow
        Stop-MlTunnelLocalProcesses -Quiet | Out-Null
    }

    $argList = @(
        "-N",
        "-o", "ServerAliveInterval=20",
        "-o", "ServerAliveCountMax=3",
        "-o", "ExitOnForwardFailure=yes",
        "-R", "$($cfg.MlTunnelRemoteBind):$($cfg.MlTunnelLocalTarget)",
        "$server"
    )
    $proc = Start-Process -FilePath $cfg.SshExe -ArgumentList $argList -PassThru -WindowStyle Minimized
    Set-Content -Path $cfg.MlTunnelPidFile -Value $proc.Id -Encoding ASCII
    Write-Info "Túnel ML iniciado. PID=$($proc.Id)" Green
    Start-Sleep -Seconds 2
    $remoteCheck = Invoke-Ssh "ss -ltnp | grep ':13003 ' || true" -Quiet
    if ($remoteCheck.Output.Trim()) {
        Write-Info "Túnel remoto activo en 13003 (TV Box)." Green
    } else {
        Write-Info "No confirmé 13003 aún; revisar conectividad si IML no procesa." Yellow
    }
    Send-StepTelegram "🧠 Túnel ML PC->NAS iniciado`nRemote: $($cfg.MlTunnelRemoteBind)`nLocal: $($cfg.MlTunnelLocalTarget)"
}

function Stop-MlTunnel {
    $local = Stop-MlTunnelLocalProcesses
    $remote = Stop-MlTunnelRemoteSide
    $localMl = Stop-LocalMlService
    $remainingLocal = @(Get-MlTunnelLocalSshProcesses).Count

    if ($remainingLocal -eq 0 -and [string]::IsNullOrWhiteSpace($remote.Output) -and [string]::IsNullOrWhiteSpace($localMl.Remaining)) {
        Write-Info "Túnel apagado y sin procesos colgados (PC + TV Box). GPU local en reposo." Green
    } else {
        Write-Info "Se limpió el túnel, pero detecté residuos. Revisar manualmente." Yellow
        if ($remote.Output) { Write-Host $remote.Output }
        if ($localMl.Remaining) { Write-Host "Contenedores locales aún escuchando puerto ML: $($localMl.Remaining)" }
    }

    Send-StepTelegram "🧠 Túnel ML PC->NAS detenido.`nPIDs locales cerrados: $($local.StoppedCount)`nContenedores ML locales detenidos: $($localMl.StoppedCount)`nResiduos ssh locales: $remainingLocal"
}

function Send-TestTelegram {
    $msg = Read-Host "Texto del mensaje"
    if ([string]::IsNullOrWhiteSpace($msg)) { return }
    Send-StepTelegram $msg
    Write-Info "Mensaje enviado (si Telegram está configurado)." Green
}

while ($true) {
    Write-Host ""
    Write-Host "========== SUPER-NAS OPS MENU ==========" -ForegroundColor Cyan
    Write-Host "1) Estado general NAS"
    Write-Host "2) Estado de colas Immich"
    Write-Host "3) Drenar IML completo (OCR/Duplicados/Sidecar/Metadata/Library/Smart/Caras)"
    Write-Host "4) Drenar IML OCR"
    Write-Host "5) Drenar IML Detección de duplicados"
    Write-Host "6) Drenar IML Sidecar metadata"
    Write-Host "7) Drenar IML Extracción de metadata"
    Write-Host "8) Drenar IML Bibliotecas externas"
    Write-Host "9) Drenar IML Búsqueda inteligente (Smart Search)"
    Write-Host "10) Drenar IML Detección de caras"
    Write-Host "11) Drenar IML Reconocimiento facial"
    Write-Host "12) Monitorear IML hasta fin + cierre túnel/normalización"
    Write-Host "13) Ejecutar video-autopilot (una corrida)"
    Write-Host "14) Ejecutar playback-audit-autoheal"
    Write-Host "15) Crear backup de estado"
    Write-Host "16) Restaurar estado"
    Write-Host "17) Ver logs clave"
    Write-Host "18) Iniciar túnel ML (usar GPU PC)"
    Write-Host "19) Detener túnel ML"
    Write-Host "20) Enviar Telegram de prueba"
    Write-Host "0) Salir"
    $opt = Read-Host "Elige opción"

    try {
        switch ($opt) {
            "1" { Show-Overview }
            "2" { Show-Queues }
            "3" { Run-ImlDrain -Targets "duplicateDetection,ocr,sidecar,metadataExtraction,library,smartSearch,faceDetection,facialRecognition" }
            "4" { Run-ImlSingle -Target "ocr" -Label "OCR" }
            "5" { Run-ImlSingle -Target "duplicateDetection" -Label "Detección de duplicados" }
            "6" { Run-ImlSingle -Target "sidecar" -Label "Sidecar metadata" }
            "7" { Run-ImlSingle -Target "metadataExtraction" -Label "Extracción de metadata" }
            "8" { Run-ImlSingle -Target "library" -Label "Bibliotecas externas" }
            "9" { Run-ImlSingle -Target "smartSearch" -Label "Búsqueda inteligente" }
            "10" { Run-ImlSingle -Target "faceDetection" -Label "Detección de caras" }
            "11" { Run-ImlSingle -Target "facialRecognition" -Label "Reconocimiento facial" }
            "12" { Run-ImlFinalize }
            "13" { Run-VideoAutopilotOnce }
            "14" { Run-PlaybackAudit }
            "15" { Run-StateBackup }
            "16" { Run-StateRestore }
            "17" { Show-KeyLogs }
            "18" { Start-MlTunnel }
            "19" { Stop-MlTunnel }
            "20" { Send-TestTelegram }
            "0" { break }
            default { Write-Info "Opción no válida." Yellow }
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}
