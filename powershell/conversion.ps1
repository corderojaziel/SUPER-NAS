# ================= CONFIGURACIÓN =================
$REMOTE_USER   = "root"
$REMOTE_HOST   = "192.168.100.89"
$REMOTE_PHOTOS = "/mnt/storage-main/photos/upload"
$REMOTE_CACHE  = "/mnt/storage-main/cache"
$LOCAL_WORK    = "C:\temp\conversion"
$REMOTE_LISTA  = "/tmp/lista_videos_automatica.txt"

# REGLA ESTRICTA: 40 MB por cada minuto de video
$UMBRAL_MB_MINUTO = 40 

if (!(Test-Path $LOCAL_WORK)) { New-Item -ItemType Directory -Force $LOCAL_WORK | Out-Null }

function Log($msg, $color = "Cyan") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color
}

# ================= 1. OBTENER LISTA =================
Log "🔍 Escaneando archivos en el NAS..."
$cmdFind = "find '$REMOTE_PHOTOS' -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.3gp' \) > $REMOTE_LISTA"
$null = cmd /c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} `"$cmdFind`""
cmd /c "scp -q -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_LISTA `"$LOCAL_WORK\lista.txt`""

$videos = Get-Content "$LOCAL_WORK\lista.txt" | Where-Object { $_ -match "\w" }
$totalAnalizar = $videos.Count
Log "✅ Lista cargada: $totalAnalizar videos encontrados."

# ================= 2. INICIALIZAR CONTADORES =================
$countIgnorados  = 0
$countProcesados = 0
$countYaEnCache  = 0
$ahorroTotalMB   = 0

# ================= 3. ANÁLISIS Y PROCESO =================
foreach ($f in $videos) {
    $f = $f.Trim()
    $basename = [System.IO.Path]::GetFileName($f)
    
    # A. Verificar si ya existe en Cache (para no repetir)
    $relPath = $f.Replace($REMOTE_PHOTOS, "").TrimStart("/")
    $safeName = $relPath -replace '[\\/:*?"<>|]', '_'
    $remoteFinal = "$REMOTE_CACHE/$([System.IO.Path]::GetFileNameWithoutExtension($safeName)).mp4"
    
    $exists = cmd /c "ssh ${REMOTE_USER}@${REMOTE_HOST} `"if [ -f '$remoteFinal' ]; then echo 1; fi`""
    if ($exists -match "1") { 
        $countYaEnCache++
        continue 
    }

    # B. Análisis de Densidad (¿Cuánto pesa por minuto?)
    $stats = cmd /c "ssh ${REMOTE_USER}@${REMOTE_HOST} `"ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1:nokey=1 '$f' `""
    $res = $stats -split "`r?`n" | Where-Object { $_ -match "^\d" }
    
    if ($res.Count -lt 2) { continue }

    $durMin = ([double]$res[0]) / 60
    $sizeMB = ([double]$res[1]) / 1MB
    if ($durMin -lt 0.01) { continue }

    $densidadActual = $sizeMB / $durMin

    # C. APLICACIÓN DE LA REGLA DE LOS 40 MB/MIN
    if ($densidadActual -le $UMBRAL_MB_MINUTO) {
        $countIgnorados++
        Log "  ⏭️ Ignorado: $basename ($([math]::Round($densidadActual,1)) MB/min)" "Gray"
        continue
    }

    # D. PROCESAR CANDIDATO
    $countProcesados++
    Log "🎯 CANDIDATO: $basename ($([math]::Round($densidadActual,1)) MB/min)" "Yellow"

    $localIn  = Join-Path $LOCAL_WORK "in_$($basename)"
    $localOut = Join-Path $LOCAL_WORK "out_$([System.IO.Path]::GetFileNameWithoutExtension($basename)).mp4"

    cmd /c "scp -q ${REMOTE_USER}@${REMOTE_HOST}:`"$f`" `"$localIn`""

    if (Test-Path $localIn) {
        # Compresión a 720p para asegurar cumplimiento de la regla
        & ffmpeg -y -hwaccel cuda -i "$localIn" `
          -c:v h264_nvenc -preset p4 -rc vbr -cq 24 -b:v 5M -maxrate 5.5M -bufsize 10M `
          -vf "scale=1280:-2" -c:a aac -b:a 128k "$localOut" 2>$null

        if (Test-Path $localOut) {
            $sizeFinalMB = (Get-Item $localOut).Length / 1MB
            $ahorroTotalMB += ($sizeMB - $sizeFinalMB)
            cmd /c "scp -q `"$localOut`" ${REMOTE_USER}@${REMOTE_HOST}:`"$remoteFinal`""
            Log "    ✅ Procesado y subido." "Green"
        }
        Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2
}

# ================= 4. REPORTE FINAL ESTRICTO =================
Write-Host "`n"
Log "===============================================" "Yellow"
Log "        RESUMEN FINAL DE LA OPERACIÓN        " "Yellow"
Log "===============================================" "Yellow"
Log " 📂 Total de videos analizados:  $totalAnalizar"
Log " ✅ Ya estaban en el cache:      $countYaEnCache"
Log " ⏭️ Ignorados (Ya eran ligeros): $countIgnorados" "Gray"
Log " 🎬 Procesados (Candidatos):     $countProcesados" "Green"
Log " 💾 Ahorro de espacio total:     $([math]::Round($ahorroTotalMB / 1024, 2)) GB" "Magenta"
Log "===============================================" "Yellow"