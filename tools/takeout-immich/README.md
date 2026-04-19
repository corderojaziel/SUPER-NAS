# Takeout -> Immich Helpers

Scripts usados para cruzar metadata de Google Takeout contra Immich y subir faltantes de forma controlada.

- `build-missing-from-zip.py`: genera CSV de faltantes comparando metadata JSON vs `originalFileName` en Immich.
- `upload-missing-to-immich.py`: sube faltantes desde ZIP hacia Immich API.
- `audit_media_only.py`: auditoría estricta solo para extensiones multimedia reales.
