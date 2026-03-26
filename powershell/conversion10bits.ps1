# ================= CONFIGURACIÓN =================
$REMOTE_USER    = "root"
$REMOTE_HOST    = "192.168.100.89"
$REMOTE_CACHE   = "/mnt/storage-main/cache"
$LOCAL_WORK     = "C:\Users\jazie\OneDrive\Escritorio\proyecto\conversion"

# ================= FUNCIONES =================
function Log($msg, $color = "Cyan") { Write-Host "[$((Get-Date).ToString('HH:mm:ss'))] $msg" -ForegroundColor $color }

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
          -vf "scale='min(1280,iw)':-2,format=yuv420p" -c:a aac -b:a 128k "$localOut"

        if (Test-Path $localOut) {
            if ((Get-Item $localOut).Length -gt 10kb) {
                
                # 3. Subida directa
                Log "📤 Subiendo a servidor..." "Blue"
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