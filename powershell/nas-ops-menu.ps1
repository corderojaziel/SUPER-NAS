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

function Send-StepTelegram {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [switch]$Strict
    )

    if ([string]::IsNullOrWhiteSpace($Message)) {
        return $false
    }

    $msgB64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Message))
    $remoteCmd = @"
python3 - <<'PY'
import base64
import subprocess
import sys

msg = base64.b64decode("$msgB64").decode("utf-8", "replace")
rc = subprocess.run(["/usr/local/bin/nas-alert.sh", msg]).returncode
print(f"nas-alert rc={rc}")
sys.exit(rc)
PY
"@

    $res = Invoke-Ssh -RemoteCommand $remoteCmd -Quiet
    if ($res.ExitCode -ne 0) {
        if ($Strict) {
            throw "No se pudo enviar Telegram. Salida: $($res.Output.Trim())"
        }
        return $false
    }
    return $true
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

function Start-MlTunnel {
    if (Test-Path $cfg.MlTunnelPidFile) {
        $oldPid = Get-Content $cfg.MlTunnelPidFile -ErrorAction SilentlyContinue
        if ($oldPid) {
            try {
                $p = Get-Process -Id ([int]$oldPid) -ErrorAction Stop
                Write-Info "Ya existe túnel activo (PID $($p.Id))." Yellow
                return
            }
            catch { }
        }
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
    Send-StepTelegram "🧠 Túnel ML PC->NAS iniciado`nRemote: $($cfg.MlTunnelRemoteBind)`nLocal: $($cfg.MlTunnelLocalTarget)"
}

function Stop-MlTunnel {
    if (!(Test-Path $cfg.MlTunnelPidFile)) {
        Write-Info "No hay PID de túnel para detener." Yellow
        return
    }
    $pidText = Get-Content $cfg.MlTunnelPidFile -ErrorAction SilentlyContinue
    if ($pidText) {
        try {
            Stop-Process -Id ([int]$pidText) -Force -ErrorAction Stop
            Write-Info "Túnel detenido (PID $pidText)." Green
            Send-StepTelegram "🧠 Túnel ML PC->NAS detenido (PID $pidText)."
        }
        catch {
            Write-Info "No pude detener PID $pidText (quizá ya terminó)." Yellow
        }
    }
    Remove-Item $cfg.MlTunnelPidFile -Force -ErrorAction SilentlyContinue
}

function Send-TestTelegram {
    $msg = Read-Host "Texto del mensaje"
    if ([string]::IsNullOrWhiteSpace($msg)) { return }
    try {
        $ok = Send-StepTelegram -Message $msg -Strict
        if ($ok) {
            Write-Info "Mensaje de Telegram enviado correctamente." Green
        }
        else {
            Write-Info "No se envió Telegram (revisar /etc/nas-secrets)." Yellow
        }
    }
    catch {
        Write-Host $_.Exception.Message -ForegroundColor Red
    }
}

while ($true) {
    Write-Host ""
    Write-Host "========== SUPER-NAS OPS MENU ==========" -ForegroundColor Cyan
    Write-Host "1) Estado general NAS | Cuando quieras una foto rápida de salud del sistema."
    Write-Host "2) Estado de colas Immich | Para ver si IML/video tienen pendientes."
    Write-Host "3) Drenar IML completo | Úsalo cuando quieras bajar todas las colas de IA."
    Write-Host "4) Drenar IML OCR | Cuando no está detectando texto nuevo en imágenes."
    Write-Host "5) Drenar IML Detección de duplicados | Cuando buscas coincidencias repetidas."
    Write-Host "6) Drenar IML Sidecar metadata | Si cambiaste sidecars y no se reflejan."
    Write-Host "7) Drenar IML Extracción de metadata | Si faltan EXIF/fecha/geo en nuevos archivos."
    Write-Host "8) Drenar IML Bibliotecas externas | Si agregaste rutas externas y no aparecen."
    Write-Host "9) Drenar IML Búsqueda inteligente | Si Smart Search no devuelve resultados nuevos."
    Write-Host "10) Drenar IML Detección de caras | Si no detecta caras en fotos recientes."
    Write-Host "11) Drenar IML Reconocimiento facial | Si no agrupa/asigna caras detectadas."
    Write-Host "12) Monitorear IML hasta fin + cierre túnel | Para dejar todo en cero y volver a modo normal."
    Write-Host "13) Ejecutar video-autopilot (una corrida) | Para avanzar reproceso sin esperar noche."
    Write-Host "14) Ejecutar playback-audit-autoheal | Para validar/reparar playback roto."
    Write-Host "15) Crear backup de estado | Antes de cambios grandes o mantenimiento delicado."
    Write-Host "16) Restaurar estado | Cuando necesites volver a snapshot conocido."
    Write-Host "17) Ver logs clave | Para diagnóstico rápido de fallos recientes."
    Write-Host "18) Iniciar túnel ML (usar GPU PC) | Si quieres procesar IML pesado fuera de TV Box."
    Write-Host "19) Detener túnel ML | Al terminar, para dejar descansar GPU/CPU local."
    Write-Host "20) Enviar Telegram de prueba | Para validar credenciales y entrega del bot."
    Write-Host "0) Salir | Cierra el menú."
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
