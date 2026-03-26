#!/bin/bash
# ═══════════════════════════════════════════════════════════════════════════
# eth-offload.sh — Activación de offloading de red en el NIC
# Guía Maestra NAS V58
# Instalado en: /etc/network/if-up.d/eth-offload (se ejecuta al levantar red)
#
# ── QUÉ HACE ─────────────────────────────────────────────────────────────
# Activa la descarga de procesamiento TCP/IP al hardware del NIC:
#
#   TSO (TCP Segmentation Offload):
#     El kernel envía segmentos TCP grandes al NIC, que los divide en
#     paquetes de tamaño correcto. Sin TSO el CPU divide cada paquete.
#     Ahorro: ~5–10% CPU durante transferencias de fotos/video.
#
#   GSO (Generic Segmentation Offload):
#     Similar a TSO pero para protocolos distintos a TCP.
#     Activo como fallback cuando TSO no está disponible.
#
#   GRO (Generic Receive Offload):
#     Agrupa múltiples paquetes recibidos antes de pasarlos al kernel.
#     Reduce las interrupciones de CPU por paquete entrante.
#     Mejora el throughput en transferencias desde el celular al NAS.
#
#   RX/TX checksums:
#     El NIC calcula y verifica checksums TCP/IP en hardware.
#     Sin esto el Cortex-A55 calcula cada checksum en software.
#
# ── COMPATIBILIDAD ───────────────────────────────────────────────────────
# No todos los NICs del S905X3 soportan todas las opciones.
# El 2>/dev/null || true evita errores si el NIC no soporta alguna opción.
# En el peor caso, el comando falla silenciosamente y el NIC funciona normal.
#
# ── PERSISTENCIA ─────────────────────────────────────────────────────────
# Se instala en if-up.d para ejecutarse automáticamente cada vez que
# la interfaz de red se levanta (incluyendo reinicios del sistema).
# ═══════════════════════════════════════════════════════════════════════════

# Detectar la interfaz con ruta por defecto (eth0, enp2s0, etc.)
# head -1 evita problemas si hay múltiples rutas por defecto
IFACE=$(ip route | grep '^default' | head -1 | awk '{print $5}')

if [ -n "$IFACE" ]; then
    ethtool -K "$IFACE" tso on gso on gro on rx on tx on 2>/dev/null || true
fi
