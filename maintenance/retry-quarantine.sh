#!/bin/bash
# Gestiona la cuarentena de videos con fallo 3/3 en video-optimize.sh.
#
# Uso:
#   /usr/local/bin/retry-quarantine.sh list
#   /usr/local/bin/retry-quarantine.sh retry "<ruta/relativa/video.ext>"
#   /usr/local/bin/retry-quarantine.sh retry-all

set -euo pipefail

STATE_DIR="/var/lib/nas-retry"
ATTEMPTS_DB="$STATE_DIR/video-optimize.attempts"
MANUAL_REVIEW="$STATE_DIR/video-optimize-manual-review.txt"

mkdir -p "$STATE_DIR"
touch "$ATTEMPTS_DB" "$MANUAL_REVIEW"

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

remove_by_key() {
    local file="$1" key="$2" tmp
    tmp="${file}.tmp.$$"
    awk -F'|' -v k="$key" '$1!=k' "$file" > "$tmp" 2>/dev/null || true
    mv "$tmp" "$file"
}

remove_manual_review_entry() {
    local rel="$1" key="$2" tmp
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

cmd="${1:-list}"

case "$cmd" in
    list)
        echo "Videos en cuarentena (manual review):"
        if [ ! -s "$MANUAL_REVIEW" ]; then
            echo "  (ninguno)"
            exit 0
        fi
        awk -F'|' '
            function trim(s) {
                sub(/^[[:space:]]+/, "", s)
                sub(/[[:space:]]+$/, "", s)
                return s
            }
            NF >= 4 {printf "  - %s | %s\n", trim($3), trim($4); next}
            NF >= 3 {printf "  - %s | %s\n", trim($2), trim($3); next}
            {printf "  - %s\n", $0}
        ' "$MANUAL_REVIEW"
        ;;

    retry)
        rel="${2:-}"
        [ -n "$rel" ] || { echo "Uso: $0 retry \"ruta/relativa/video.ext\""; exit 1; }
        key="$(get_key "$rel")"
        remove_by_key "$ATTEMPTS_DB" "$key"
        remove_manual_review_entry "$rel" "$key"
        echo "Reactivado para reintento: $rel"
        /usr/local/bin/nas-alert.sh "🔁 Un video volverá a intentarse
Archivo: $rel
La próxima rutina nocturna lo procesará de nuevo." || true
        ;;

    retry-all)
        cp "$MANUAL_REVIEW" "${MANUAL_REVIEW}.bak.$(date +%F-%H%M%S)" 2>/dev/null || true
        : > "$MANUAL_REVIEW"
        : > "$ATTEMPTS_DB"
        echo "Todos los videos en cuarentena fueron reactivados."
        /usr/local/bin/nas-alert.sh "🔁 Todos los videos pausados volverán a intentarse
Se limpió la lista de cuarentena manual." || true
        ;;

    *)
        echo "Comando no valido: $cmd"
        echo "Uso:"
        echo "  $0 list"
        echo "  $0 retry \"ruta/relativa/video.ext\""
        echo "  $0 retry-all"
        exit 1
        ;;
esac
