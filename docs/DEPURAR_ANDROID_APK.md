# Depurar Android APK

App Android para calcular cuánto espacio se puede liberar de `DCIM/Camera` conservando los últimos `30`, `60`, `90`, `120` o `180` días. Antes de borrar, consulta el INX y solo permite eliminar videos confirmados en Immich y físicamente presentes en el almacenamiento del NAS.

## DNS usado

La app trae como API predeterminada:

```text
http://aml-s9xx-box.taile292fd.ts.net:8787
```

El campo es editable dentro de la app.

## Instalar API en INX

En la TV box/INX:

```bash
cd /ruta/SUPER-NAS
sudo bash maintenance/depurar-android-api-install.sh
curl http://aml-s9xx-box.taile292fd.ts.net:8787/health
```

Con token opcional:

```bash
sudo DEPURAR_ANDROID_TOKEN="cambia-esto" bash maintenance/depurar-android-api-install.sh
```

Si configuras token, escríbelo también en la app.

## Compilar APK

Este repo deja el proyecto en:

```text
android/DepurarAndroid
```

En una máquina con Android Studio o Android SDK:

```bash
cd android/DepurarAndroid
gradle assembleDebug
```

APK esperada:

```text
android/DepurarAndroid/app/build/outputs/apk/debug/app-debug.apk
```

También puedes abrir `android/DepurarAndroid` en Android Studio y usar **Build > Build APK(s)**.

## Flujo de uso

1. Conecta el teléfono a Tailscale para que resuelva `aml-s9xx-box.taile292fd.ts.net`.
2. Abre la app.
3. Elige `30`, `60`, `90`, `120` o `180` días.
4. Toca `Calcular espacio liberable`.
5. Revisa el resumen de videos confirmados y GB liberables.
6. Toca `Borrar confirmados`.
7. Android mostrará su confirmación de borrado; acepta si el resumen es correcto.

## Seguridad

- La APK no tiene credenciales de PostgreSQL ni SSH.
- La validación de Immich ocurre en el INX mediante `depurar-android-api.py`.
- El API confirma por `nombre + tamaño exacto` y además verifica que el archivo exista en `/mnt/merged`.
- La app ignora archivos ocultos `.temp*`, `.trashed*` y archivos de tamaño cero.
- La app solo maneja videos en `DCIM/Camera` en esta primera versión.
