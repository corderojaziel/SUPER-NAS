#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# video-optimize.sh — Compresión nocturna solo para videos pesados
# Guía Maestra NAS V58
#
# OBJETIVO
#   Generar derivados ligeros SOLO para videos que exceden la meta de peso
#   por minuto para reproducción remota. Esto corre solo en ventana nocturna
#   y solo si el sistema está sano (mounts, SMART, eMMC y DB).
#
# AYUDA PARA REVISIÓN POR IA
#   Validar:
#   1) que VIDEO_OPTIMIZE_WINDOW_START/END cubran la ventana deseada
#   2) que mount-status.env, smart-status.env, storage-status.env y
#      db-status.env existan y reflejen el estado correcto
#   3) que no se procese fuera de ventana ni con estado CRIT
#   4) que el temporal .tmp se valide antes del mv final
# ═══════════════════════════════════════════════════════════════════════════

set -u

INPUT="/mnt/storage-main/photos"
OUTPUT="/var/lib/immich/cache"
STATE_DIR="/var/lib/nas-retry"
HEALTH_DIR="/var/lib/nas-health"
SUMMARY_FILE="$HEALTH_DIR/video-optimize-summary.env"
ATTEMPTS_DB="$STATE_DIR/video-optimize.attempts"
FAIL_REPORT="$STATE_DIR/video-optimize-failures.log"
MANUAL_REVIEW="$STATE_DIR/video-optimize-manual-review.txt"
LOCK_FILE="/var/lock/video-optimize.lock"
POLICY_FILE="/etc/default/nas-video-policy"
[ -f "$POLICY_FILE" ] && . "$POLICY_FILE"
PER_FILE_TIMEOUT_SEC="${VIDEO_OPTIMIZE_TIMEOUT_SEC:-600}"
VIDEO_OPTIMIZE_WINDOW_START="${VIDEO_OPTIMIZE_WINDOW_START:-01}"
VIDEO_OPTIMIZE_WINDOW_END="${VIDEO_OPTIMIZE_WINDOW_END:-06}"
VIDEO_OPTIMIZE_CURRENT_HOUR="${VIDEO_OPTIMIZE_CURRENT_HOUR:-${NAS_CURRENT_HOUR:-$(date +%H)}}"
VIDEO_STREAM_MAX_MB_PER_MIN="${VIDEO_STREAM_MAX_MB_PER_MIN:-40}"
VIDEO_STREAM_TARGET_MB_PER_MIN="${VIDEO_STREAM_TARGET_MB_PER_MIN:-38}"
VIDEO_STREAM_LIGHT_REENCODE_MAX_MB_PER_MIN="${VIDEO_STREAM_LIGHT_REENCODE_MAX_MB_PER_MIN:-55}"
VIDEO_OPTIMIZE_AUDIO_BITRATE_K="${VIDEO_OPTIMIZE_AUDIO_BITRATE_K:-128}"
VIDEO_OPTIMIZE_MAX_LONG_EDGE="${VIDEO_OPTIMIZE_MAX_LONG_EDGE:-1920}"
VIDEO_OPTIMIZE_VIDEO_LEVEL="${VIDEO_OPTIMIZE_VIDEO_LEVEL:-4.1}"

mkdir -p "$OUTPUT" "$STATE_DIR" "$HEALTH_DIR" "$(dirname "$LOCK_FILE")"
touch "$ATTEMPTS_DB" "$FAIL_REPORT" "$MANUAL_REVIEW"

alert() { /usr/local/bin/nas-alert.sh "$1"; }
log() { echo "[$(date '+%F %T')] $1" >> "$STATE_DIR/video-optimize.log"; }

VIDEO_TOTAL_COUNT=0
VIDEO_DIRECT_COUNT=0
VIDEO_READY_COUNT=0
VIDEO_OPTIMIZED_COUNT=0
VIDEO_PENDING_COUNT=0
VIDEO_MANUAL_REVIEW_COUNT=0

write_summary() {
    cat > "$SUMMARY_FILE" <<EOF
VIDEO_SUMMARY_TS=$(date -Iseconds)
VIDEO_TOTAL_COUNT=${VIDEO_TOTAL_COUNT}
VIDEO_DIRECT_COUNT=${VIDEO_DIRECT_COUNT}
VIDEO_READY_COUNT=${VIDEO_READY_COUNT}
VIDEO_OPTIMIZED_COUNT=${VIDEO_OPTIMIZED_COUNT}
VIDEO_PENDING_COUNT=${VIDEO_PENDING_COUNT}
VIDEO_MANUAL_REVIEW_COUNT=${VIDEO_MANUAL_REVIEW_COUNT}
EOF
}

write_summary

remove_by_key() {
    local file="$1" key="$2" tmp
    tmp="${file}.tmp.$$"
    awk -F'|' -v k="$key" '$1!=k' "$file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

clear_manual_review() {
    local key="$1" rel="$2" tmp
    tmp="${MANUAL_REVIEW}.tmp.$$"
    awk -F'|' -v k="$key" -v r="$rel" '
        function trim(s) {
            sub(/^[[:space:]]+/, "", s)
            sub(/[[:space:]]+$/, "", s)
            return s
        }
        {
            f1=trim($1)
            f2=trim($2)
            f3=trim($3)
            if (!(f1==k || f2==r || f3==r)) {
                print $0
            }
        }
    ' "$MANUAL_REVIEW" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$MANUAL_REVIEW"
}

load_status_env() {
  local file="$1"
  [ -f "$file" ] && . "$file"
}

load_status_env "$HEALTH_DIR/mount-status.env"
load_status_env "$HEALTH_DIR/smart-status.env"
load_status_env "$HEALTH_DIR/storage-status.env"
load_status_env "$HEALTH_DIR/db-status.env"

MOUNT_STATUS="${GLOBAL_MOUNT_STATUS:-OK}"
SMART_STATUS="${GLOBAL_SMART_STATUS:-OK}"
EMMC_STATUS="${EMMC_STATUS:-OK}"
DB_STATUS="${DB_STATUS:-OK}"

is_in_window() {
  local start="$1" end="$2" now="$3"
  if [ "$start" -lt "$end" ]; then
    [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]
    return
  fi
  if [ "$start" -gt "$end" ]; then
    [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]
    return
  fi
  return 0
}

current_hour="$VIDEO_OPTIMIZE_CURRENT_HOUR"
if ! is_in_window "$VIDEO_OPTIMIZE_WINDOW_START" "$VIDEO_OPTIMIZE_WINDOW_END" "$current_hour"; then
  log "Fuera de ventana permitida (${VIDEO_OPTIMIZE_WINDOW_START}:00-${VIDEO_OPTIMIZE_WINDOW_END}:00), saliendo"
  alert "🌙 La optimización de videos quedó pospuesta
Esta tarea solo corre por la noche, entre ${VIDEO_OPTIMIZE_WINDOW_START}:00 y ${VIDEO_OPTIMIZE_WINDOW_END}:00.
Así evitamos que el NAS se ponga lento durante el día."
  exit 0
fi

if [ "$MOUNT_STATUS" = "CRIT" ]; then
  log "Mounts en CRIT, saliendo"
  alert "⏭️ Hoy no optimicé videos
No pude ver bien los discos del NAS.
Para evitar errores, prefiero esperar a que todo vuelva a estar estable."
  exit 0
fi
if [ "$SMART_STATUS" = "CRIT" ]; then
  log "SMART en CRIT, saliendo"
  alert "⏭️ Hoy no optimicé videos
Uno de los discos reportó un problema serio.
Para no forzarlo más, esta tarea quedó pausada."
  exit 0
fi
if [ "$EMMC_STATUS" = "CRIT" ]; then
  log "eMMC en CRIT, saliendo"
  alert "⏭️ Hoy no optimicé videos
La memoria interna del NAS está casi llena.
Para cuidarla, no generé versiones ligeras esta noche."
  exit 0
fi
if [ "$DB_STATUS" = "CRIT" ]; then
  log "DB en CRIT, saliendo"
  alert "⏭️ Hoy no optimicé videos
La base de datos de Immich no está disponible.
Prefiero esperar a que el sistema vuelva a estar sano."
  exit 0
fi

exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  log "Ya está corriendo otra instancia"
  alert "⏭️ Ya había una optimización de videos en marcha
No lancé otra para no duplicar trabajo ni cargar de más el NAS."
  exit 0
fi

sanitize_field() {
    printf '%s' "$1" | tr '\n|' '   '
}

get_key() {
    local value="$1"
    if command -v sha1sum >/dev/null 2>&1; then
        printf '%s' "$value" | sha1sum | awk '{print $1}'
    elif command -v md5sum >/dev/null 2>&1; then
        printf '%s' "$value" | md5sum | awk '{print $1}'
    else
        printf '%s' "$value" | cksum | awk '{print $1}'
    fi
}

get_attempts() {
    local key="$1"
    awk -F'|' -v k="$key" '$1==k{print $2; found=1} END{if(!found) print 0}' "$ATTEMPTS_DB"
}

get_size_bytes() {
    local src="$1"
    stat -Lc '%s' "$src" 2>/dev/null || echo 0
}

get_duration_seconds() {
    local src="$1"
    ffprobe -v error -show_entries format=duration -of default=nokey=1:noprint_wrappers=1 "$src" 2>/dev/null | awk 'NF{print; exit}'
}

get_allowed_bytes() {
    local duration="$1"
    awk -v sec="$duration" -v mbpm="$VIDEO_STREAM_MAX_MB_PER_MIN" 'BEGIN{ printf "%.0f", (sec * mbpm * 1000000) / 60 }'
}

get_mb_per_min() {
    local src="$1" size duration
    size=$(get_size_bytes "$src")
    duration=$(get_duration_seconds "$src")
    [ -n "$duration" ] || return 1
    awk -v size="$size" -v sec="$duration" 'BEGIN{ if (sec <= 0) { print 0 } else { printf "%.2f", (size / 1000000) / (sec / 60) } }'
}

is_direct_play_candidate() {
    local src="$1" size duration allowed
    size=$(get_size_bytes "$src")
    duration=$(get_duration_seconds "$src")
    [ -n "$duration" ] || return 1
    allowed=$(get_allowed_bytes "$duration")
    awk -v size="$size" -v allowed="$allowed" 'BEGIN{ exit(size <= allowed ? 0 : 1) }'
}

ensure_direct_cache_link() {
    local src="$1" out="$2" dir src_size out_size tmp_copy
    dir="$(dirname "$out")"
    mkdir -p "$dir"
    src_size=$(get_size_bytes "$src")

    if [ -L "$out" ]; then
        local current_target
        current_target=$(readlink "$out" 2>/dev/null || true)
        if [ "$current_target" = "$src" ]; then
            return 0
        fi
        rm -f "$out"
    elif [ -f "$out" ]; then
        out_size=$(get_size_bytes "$out")
        if [ "$out_size" = "$src_size" ]; then
            return 0
        fi
        return 1
    elif [ -e "$out" ]; then
        return 1
    fi

    if ln -s "$src" "$out" 2>/dev/null; then
        return 0
    fi

    tmp_copy="${out}.tmp-copy.$$"
    if cp -f "$src" "$tmp_copy" 2>/dev/null && mv -f "$tmp_copy" "$out" 2>/dev/null; then
        return 0
    fi

    rm -f "$tmp_copy"
    return 1
}

set_attempts() {
    local key="$1" attempts="$2"
    if [ "$attempts" -le 0 ] 2>/dev/null; then
        remove_by_key "$ATTEMPTS_DB" "$key"
        return 0
    fi
    awk -F'|' -v k="$key" -v a="$attempts" 'BEGIN{updated=0} $1==k{print k"|"a; updated=1; next} {print} END{if(!updated) print k"|"a}' "$ATTEMPTS_DB" > "$ATTEMPTS_DB.tmp" && mv "$ATTEMPTS_DB.tmp" "$ATTEMPTS_DB"
}

record_failure() {
    local src="$1" rel="$2" reason="$3" attempts="$4"
    printf '%s|%s|%s|%s\n' "$(date -Iseconds)" "$(sanitize_field "$src")" "$(sanitize_field "$rel")" "$(sanitize_field "$reason") (intento ${attempts}/3)" >> "$FAIL_REPORT"
}

mark_manual_review() {
    local key="$1" src="$2" rel="$3" reason="$4"
    clear_manual_review "$key" "$rel"
    printf '%s|%s|%s|%s\n' "$key" "$(sanitize_field "$src")" "$(sanitize_field "$rel")" "$(sanitize_field "$reason")" >> "$MANUAL_REVIEW"
}

while IFS= read -r -d '' src; do
  VIDEO_TOTAL_COUNT=$((VIDEO_TOTAL_COUNT + 1))
  rel="${src#$INPUT/}"
  out="$OUTPUT/${rel%.*}.mp4"
  tmp="${out}.tmp.mp4"
  mkdir -p "$(dirname "$out")"

  if is_direct_play_candidate "$src"; then
    VIDEO_DIRECT_COUNT=$((VIDEO_DIRECT_COUNT + 1))
    if ensure_direct_cache_link "$src" "$out"; then
      log "Cache directo listo sin recompresion: $rel"
    else
      log "No pude crear enlace directo en cache: $rel"
    fi
    continue
  fi

  if [ -L "$out" ]; then
    rm -f "$out"
  fi
  if [ -f "$out" ]; then
    VIDEO_READY_COUNT=$((VIDEO_READY_COUNT + 1))
    continue
  fi

  key=$(get_key "$rel")
  attempts=$(get_attempts "$key")
  if [ "$attempts" -ge 3 ]; then
    VIDEO_MANUAL_REVIEW_COUNT=$((VIDEO_MANUAL_REVIEW_COUNT + 1))
    continue
  fi

  log "Convirtiendo: $rel"
  current_mbpm=$(get_mb_per_min "$src")
  target_total_kbps=$(awk -v mbpm="$VIDEO_STREAM_TARGET_MB_PER_MIN" 'BEGIN{ printf "%.0f", (mbpm * 8000) / 60 }')
  target_video_kbps=$((target_total_kbps - VIDEO_OPTIMIZE_AUDIO_BITRATE_K))
  [ "$target_video_kbps" -lt 700 ] && target_video_kbps=700
  if awk -v cur="$current_mbpm" -v light="$VIDEO_STREAM_LIGHT_REENCODE_MAX_MB_PER_MIN" 'BEGIN{ exit(cur <= light ? 0 : 1) }'; then
    if [ "${VIDEO_OPTIMIZE_MAX_LONG_EDGE:-0}" -gt 0 ]; then
      scale_filter="scale=${VIDEO_OPTIMIZE_MAX_LONG_EDGE}:${VIDEO_OPTIMIZE_MAX_LONG_EDGE}:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    else
      scale_filter="scale=trunc(iw/2)*2:trunc(ih/2)*2"
    fi
    video_preset="veryfast"
  else
    if [ "${VIDEO_OPTIMIZE_MAX_LONG_EDGE:-0}" -gt 0 ]; then
      scale_filter="scale=${VIDEO_OPTIMIZE_MAX_LONG_EDGE}:${VIDEO_OPTIMIZE_MAX_LONG_EDGE}:force_original_aspect_ratio=decrease,scale=trunc(iw/2)*2:trunc(ih/2)*2"
    else
      scale_filter="scale=trunc(iw/2)*2:trunc(ih/2)*2"
    fi
    video_preset="superfast"
  fi

  if timeout "$PER_FILE_TIMEOUT_SEC" nice -n 15 ffmpeg -y -i "$src" \
      -vf "$scale_filter" \
      -c:v libx264 -preset "$video_preset" -b:v "${target_video_kbps}k" -maxrate "${target_video_kbps}k" -bufsize "$((target_video_kbps * 2))k" \
      -profile:v high -level:v "$VIDEO_OPTIMIZE_VIDEO_LEVEL" \
      -c:a aac -b:a "${VIDEO_OPTIMIZE_AUDIO_BITRATE_K}k" \
      -pix_fmt yuv420p -movflags +faststart "$tmp" >/dev/null 2>&1; then
    if [ -s "$tmp" ]; then
      mv "$tmp" "$out"
      set_attempts "$key" 0
      clear_manual_review "$key" "$rel"
      VIDEO_OPTIMIZED_COUNT=$((VIDEO_OPTIMIZED_COUNT + 1))
    else
      rm -f "$tmp"
      attempts=$((attempts+1))
      set_attempts "$key" "$attempts"
      record_failure "$src" "$rel" "salida temporal vacía" "$attempts"
      if [ "$attempts" -ge 3 ]; then
        mark_manual_review "$key" "$src" "$rel" "salida temporal vacía"
        VIDEO_MANUAL_REVIEW_COUNT=$((VIDEO_MANUAL_REVIEW_COUNT + 1))
      else
        VIDEO_PENDING_COUNT=$((VIDEO_PENDING_COUNT + 1))
      fi
    fi
  else
    rc=$?
    rm -f "$tmp"
    attempts=$((attempts+1))
    set_attempts "$key" "$attempts"
    reason="ffmpeg"
    [ "$rc" -eq 124 ] && reason="timeout"
    record_failure "$src" "$rel" "$reason" "$attempts"
    if [ "$attempts" -ge 3 ]; then
      mark_manual_review "$key" "$src" "$rel" "$reason"
      VIDEO_MANUAL_REVIEW_COUNT=$((VIDEO_MANUAL_REVIEW_COUNT + 1))
    else
      VIDEO_PENDING_COUNT=$((VIDEO_PENDING_COUNT + 1))
    fi
  fi
done < <(find "$INPUT" -type f \( -iname '*.mp4' -o -iname '*.mov' -o -iname '*.mkv' -o -iname '*.avi' -o -iname '*.webm' \) -print0 2>/dev/null)

write_summary
exit 0
