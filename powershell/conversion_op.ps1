# ================= CONFIGURACIÓN =================
$REMOTE_USER    = "root"
$REMOTE_HOST    = "192.168.100.89"
$REMOTE_PHOTOS  = "/mnt/storage-main/photos/upload"
$REMOTE_CACHE   = "/mnt/storage-main/cache"
$LOCAL_WORK     = "C:\temp\conversion"
$REMOTE_LISTA   = "/tmp/lista_videos_automatica.txt"

# REGLA ESTRICTA: 40 MB por cada minuto de video
$UMBRAL_MB_MINUTO = 40 

if (!(Test-Path $LOCAL_WORK)) { New-Item -ItemType Directory -Force $LOCAL_WORK | Out-Null }

function Log($msg, $color = "Cyan") {
    Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color
}

# ================= 1. OBTENER LISTA DE ORIGINALES =================
Log "🔍 Escaneando archivos originales en el NAS..."
$cmdFind = "find '$REMOTE_PHOTOS' -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.avi' -o -iname '*.mkv' -o -iname '*.3gp' \)"
$null = cmd /c "ssh -o BatchMode=yes -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST} `"$cmdFind > $REMOTE_LISTA`""
cmd /c "scp -q -o StrictHostKeyChecking=no ${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_LISTA `"$LOCAL_WORK\lista.txt`""

if (!(Test-Path "$LOCAL_WORK\lista.txt")) { Log "❌ Error: No se pudo obtener la lista."; exit }

$videos = Get-Content "$LOCAL_WORK\lista.txt" | Where-Object { $_ -match "\w" }
$totalAnalizar = $videos.Count
Log "✅ Lista cargada: $totalAnalizar videos encontrados."

# ================= 2. INICIALIZAR CONTADORES =================
$countIgnorados  = 0
$countProcesados = 0
$countYaEnCache  = 0
$ahorroTotalMB   = 0

# ================= 3. ANÁLISIS Y PROCESO INCREMENTAL =================
foreach ($f in $videos) {
    $f = $f.Trim()
    $basename = [System.IO.Path]::GetFileName($f)
    
    # --- REGLA: REVISAR EN CACHÉ DEL NAS ---
    # Buscamos el archivo directamente en la carpeta cache
    $remoteFinal = "$REMOTE_CACHE/$basename"
    
    # Verificamos existencia mediante SSH para no descargar por error
    $exists = cmd /c "ssh ${REMOTE_USER}@${REMOTE_HOST} `"if [ -f '$remoteFinal' ]; then echo 1; fi`""
    
    if ($exists -match "1") { 
        $countYaEnCache++
        # Opcional: Log "  ⏭️ Saltando (Ya está en cache): $basename" "DarkGray"
        continue 
    }

    # --- ANÁLISIS DE DENSIDAD (¿Vale la pena comprimir?) ---
    $stats = cmd /c "ssh ${REMOTE_USER}@${REMOTE_HOST} `"ffprobe -v error -show_entries format=duration,size -of default=noprint_wrappers=1:nokey=1 '$f' `""
    $res = $stats -split "`r?`n" | Where-Object { $_ -match "^\d" }
    
    if ($res.Count -lt 2) { continue }

    $durMin = ([double]$res[0]) / 60
    $sizeMB = ([double]$res[1]) / 1MB
    if ($durMin -lt 0.01) { continue }

    $densidadActual = $sizeMB / $durMin

    # --- REGLA DE LOS 40 MB/MIN ---
    if ($densidadActual -le $UMBRAL_MB_MINUTO) {
        $countIgnorados++
        continue
    }

    # --- PROCESAMIENTO (GPU LOCAL) ---
    $countProcesados++
    Log "🎯 CANDIDATO: $basename ($([math]::Round($densidadActual,1)) MB/min)" "Yellow"

    $localIn  = Join-Path $LOCAL_WORK "in_$($basename)"
    $localOut = Join-Path $LOCAL_WORK "out_$($basename)"

    # Descarga desde NAS a PC local
    cmd /c "scp -q ${REMOTE_USER}@${REMOTE_HOST}:`"$f`" `"$localIn`""

    if (Test-Path $localIn) {
        # Configuración NVENC balanceada para cumplir los 40MB/min
        & ffmpeg -y -hwaccel cuda -i "$localIn" `
          -c:v h264_nvenc -preset p4 -rc vbr -cq 28 -b:v 3M -maxrate 4.5M -bufsize 9M `
          -vf "scale='min(1280,iw)':-2" -c:a aac -b:a 128k "$localOut" 2>$null

        if (Test-Path $localOut) {
            $sizeFinalMB = (Get-Item $localOut).Length / 1MB
            
            # Solo subimos si el ahorro es real
            if ($sizeFinalMB -lt $sizeMB) {
                $ahorroTotalMB += ($sizeMB - $sizeFinalMB)
                cmd /c "scp -q `"$localOut`" ${REMOTE_USER}@${REMOTE_HOST}:`"$remoteFinal`""
                Log "    ✅ Procesado y subido a cache: $([math]::Round($sizeFinalMB,1)) MB" "Green"
            } else {
                Log "    ⚠️ No hubo ahorro de espacio. Saltando subida." "Red"
            }
        }
        # Limpiar archivos temporales de la PC
        Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
    }
    # Respiro para el disco/red
    Start-Sleep -Seconds 1
}

# ================= 4. REPORTE FINAL =================
Write-Host "`n"
Log "===============================================" "Yellow"
Log "      REPORTE DE ALMACENAMIENTO (QUERÉTARO)    " "Yellow"
Log "===============================================" "Yellow"
Log " 📂 Total de videos originales:   $totalAnalizar"
Log " ✅ Encontrados en /cache:        $countYaEnCache"
Log " ⏭️ Ignorados (Baja densidad):    $countIgnorados" "Gray"
Log " 🎬 Procesados en esta sesión:    $countProcesados" "Green"
Log " 💾 Ahorro de espacio total:      $([math]::Round($ahorroTotalMB / 1024, 2)) GB" "Magenta"
Log "===============================================" "Yellow"