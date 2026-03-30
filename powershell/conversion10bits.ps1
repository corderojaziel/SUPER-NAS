# ================= CONFIGURACIÓN =================
$REMOTE_USER    = "root"
$REMOTE_HOST    = "192.168.100.89"
$REMOTE_CACHE   = "/var/lib/immich/cache/upload"
$LOCAL_WORK     = "C:\Users\jazie\OneDrive\Escritorio\proyecto\conversion"

# ================= FUNCIONES =================
function Log($msg, $color = "Cyan") { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color }
$ScaleFilter = "scale=1920:1920:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2,format=yuv420p"

# 1. Buscar archivos que ya están descargados (in_...)
$archivosIn = Get-ChildItem -Path $LOCAL_WORK -Filter "in_*.mp4"

if ($archivosIn.Count -eq 0) {
    Log "⚠️ No hay archivos 'in_*.mp4' pendientes en $LOCAL_WORK" "Yellow"
    exit
}

Log "🚀 Reprocesando $($archivosIn.Count) archivos locales con HEVC (Fix 10-bit)..."

foreach ($file in $archivosIn) {
    try {
        # Limpiamos el nombre para el archivo de salida y destino
        $cleanName = $file.Name -replace "^in_", ""
        $localOut  = Join-Path $LOCAL_WORK "out_$cleanName"
        $remoteDest = "${REMOTE_USER}@${REMOTE_HOST}:$REMOTE_CACHE/$cleanName"

        Log "🎬 Convirtiendo: $cleanName" "White"

        # 2. Conversión HEVC + CUDA + Fix de color (format=yuv420p)
        & ffmpeg -y -hwaccel cuda -i $file.FullName `
          -c:v hevc_nvenc -preset p4 -rc vbr -cq 28 -b:v 3M -maxrate 4.5M -bufsize 9M `
          -vf "$ScaleFilter" -profile:v main -level:v 4.1 `
          -c:a aac -b:a 128k -movflags +faststart "$localOut"

        if (Test-Path $localOut) {
            if ((Get-Item $localOut).Length -gt 10kb) {
                
                # 3. Subida directa
                Log "📤 Subiendo a servidor..." "Blue"
                ssh -o BatchMode=yes "${REMOTE_USER}@${REMOTE_HOST}" "mkdir -p '$REMOTE_CACHE'" | Out-Null
                & scp -q "$localOut" "$remoteDest"

                if ($LASTEXITCODE -eq 0) {
                    Log "✅ OK: $cleanName subido." "Green"
                    # Borramos ambos para dejar espacio
                    Remove-Item $file.FullName, $localOut -Force -ErrorAction SilentlyContinue
                } else {
                    Log "❌ Error de red al subir $cleanName" "Red"
                }
            } else {
                Log "⚠️ FFmpeg generó un archivo vacío." "Red"
                Remove-Item $localOut -Force
            }
        }
    } catch {
        Log "❌ Error con $($file.Name): $($_.Exception.Message)" "Red"
    }
}

Log "🏁 TERMINADO. Carpeta local limpia."
