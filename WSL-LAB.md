# Laboratorio WSL (Ubuntu)

Este repo ya soporta un perfil separado para pruebas en Ubuntu WSL sin tocar
el perfil real de Armbian.

## 1. Instalar y abrir Ubuntu una vez

En Windows PowerShell:

```powershell
wsl --install Ubuntu
```

Luego abre `Ubuntu` desde el menu Inicio y completa el alta inicial del usuario
Linux. Si Ubuntu ya estaba instalada pero se quedo a medias, basta con abrirla
una vez y terminar ese paso.

## 2. Activar systemd en WSL

Dentro de Ubuntu:

```bash
sudo tee /etc/wsl.conf >/dev/null <<'EOF'
[boot]
systemd=true
EOF
exit
```

De vuelta en PowerShell:

```powershell
wsl --shutdown
```

Abre otra vez `Ubuntu`.

## 3. Preparar dependencias minimas

Dentro de Ubuntu:

```bash
sudo apt update
sudo apt install -y util-linux coreutils parted dos2unix
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo dos2unix install.sh precheck.sh scripts/*.sh maintenance/*.sh verify.sh check-tuning.sh
```

## 4. Levantar el laboratorio WSL

Preparar discos loop y perfil generado:

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo bash scripts/wsl-lab-prepare.sh
```

Instalar todo el stack con el perfil WSL:

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo bash scripts/wsl-lab-install.sh
```

## 5. Prueba de instalacion

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo NAS_CONFIG_FILE=/mnt/c/Users/jazie/OneDrive/Escritorio/proyecto/config/nas.wsl.generated.conf bash precheck.sh
sudo /usr/local/bin/verify.sh
cd /opt/immich-app && sudo docker compose ps
```

## 6. Happy path funcional

Sube o copia un video de prueba al arbol de originales y luego valida:

```bash
sudo /usr/local/bin/post-upload-check.sh
sudo /usr/local/bin/post-upload-check.sh library/demo/test-video.mp4
```

Si quieres forzar la rutina nocturna:

```bash
sudo ML_WINDOW_HOUR=02 /usr/local/bin/night-run.sh
```

## 7. Flujos alternos y mensajes

Cobertura local sin Telegram real:

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo ALERT_MODE=fake bash maintenance/test-alert-coverage.sh
```

Envio real a Telegram:

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo REAL_TELEGRAM_TOKEN=TU_TOKEN REAL_TELEGRAM_CHAT_ID=TU_CHAT ALERT_MODE=real bash maintenance/test-alert-coverage.sh
```

## 8. Limpiar el laboratorio

```bash
cd /mnt/c/Users/jazie/OneDrive/Escritorio/proyecto
sudo bash scripts/wsl-lab-clean.sh
```
