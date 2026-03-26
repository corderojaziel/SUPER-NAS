# ================= CONFIGURACIÓN =================
$REMOTE_USER    = "root"
$REMOTE_HOST    = "192.168.100.89"
$REMOTE_CACHE   = "/mnt/storage-main/cache"
$LOCAL_WORK     = "C:\Users\jazie\OneDrive\Escritorio\proyecto\conversion"

# Asegúrate de que este nombre sea el correcto de tu lista actual
$INPUT_FILE     = "C:\Users\jazie\OneDrive\Escritorio\faltantes_full.txt"
$OUTPUT_FILE    = "C:\Users\jazie\OneDrive\Escritorio\faltantes_restantes.txt"

# ================= PREPARACIÓN =================
if (!(Test-Path $LOCAL_WORK)) { New-Item -ItemType Directory -Force -Path $LOCAL_WORK | Out-Null }
function Log($msg, $color = "Cyan") { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color }

# ================= CARGA =================
if (!(Test-Path $INPUT_FILE)) { Log "❌ No se encuentra el archivo de entrada"; exit }
$videos = Get-Content $INPUT_FILE | Where-Object { $_ -match "\|" }
[System.Collections.Generic.List[string]]$restantes = [System.Collections.Generic.List[string]]::new()
foreach($v in $videos) { $restantes.Add($v) }

Log "🚀 Iniciando Modo HEVC (Fix 10-bit HDR)..."

foreach ($line in $videos) {
    try {
        $parts = $line -split "\|"
        if ($parts.Count -lt 2) { continue }
        
        $remotePath = $parts[0].Trim()
        $basename   = $parts[1].Trim()
        $remoteFinal = "$REMOTE_CACHE/$basename"

        Log "🔍 [$($restantes.Count) faltantes] Procesando: $basename" "White"

        # 1. Verificar si ya existe en Cache
        $check = ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "if [ -f '$remoteFinal' ]; then echo 1; fi"
        if ($check -eq "1") { 
            Log "⏭️ Ya existe en Cache, saltando..." "Gray"
            $null = $restantes.Remove($line)
            $restantes | Set-Content $OUTPUT_FILE
            continue 
        }

        $localIn  = Join-Path $LOCAL_WORK "in_$basename"
        $localOut = Join-Path $LOCAL_WORK "out_$basename"

        # 2. Descarga
        Log "📡 Descargando..." "Yellow"
        $scpSource = "${REMOTE_USER}@${REMOTE_HOST}:$remotePath"
        scp -q $scpSource "$localIn"

        if (!(Test-Path $localIn)) {
            Log "❌ Error: SCP no pudo bajar el archivo." "Red"
            continue
        }

        # 3. Conversión GPU (HEVC + Fix de 10 bits)
        Log "🎬 Convirtiendo con HEVC (H.265)..." "Magenta"
        # El filtro format=yuv420p es el que evita el error de "10 bit not supported"
        ffmpeg -y -hwaccel cuda -i "$localIn" `
          -c:v hevc_nvenc -preset p4 -rc vbr -cq 28 -b:v 3M -maxrate 4.5M -bufsize 9M `
          -vf "scale='min(1280,iw)':-2,format=yuv420p" -c:a aac -b:a 128k "$localOut"

        if (Test-Path $localOut) {
            if ((Get-Item $localOut).Length -gt 10kb) {
                # 4. Subida
                Log "📤 Subiendo a servidor..." "Blue"
                $scpDest = "${REMOTE_USER}@${REMOTE_HOST}:$remoteFinal"
                scp -q "$localOut" $scpDest
                
                Log "✅ OK: $basename" "Green"
                
                # Limpieza y actualización
                Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
                $null = $restantes.Remove($line)
                $restantes | Set-Content $OUTPUT_FILE
            } else {
                Log "⚠️ Archivo de salida demasiado pequeño, posible fallo silencioso." "Red"
                Remove-Item $localIn, $localOut -Force -ErrorAction SilentlyContinue
            }
        } else {
            Log "❌ Error: FFmpeg falló (No se generó archivo)." "Red"
            if (Test-Path $localIn) { Remove-Item $localIn -Force }
        }

    } catch {
        Log "❌ Error inesperado: $($_.Exception.Message)" "Red"
    }
}

Log "🏁 PROCESO TERMINADO"