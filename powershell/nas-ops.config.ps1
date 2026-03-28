@{
    SshExe = "ssh"
    ScpExe = "scp"
    WslExe = "wsl"

    ServerUser = "root"
    ServerHost = "192.168.100.89"
    ConnectTimeoutSec = 20

    # Túnel ML remoto (para usar GPU de la PC con Immich del NAS).
    # El proxy del NAS escucha 127.0.0.1:13031 y reenvía a 127.0.0.1:13003.
    # Este túnel abre 13003 en NAS y lo conecta a tu servicio ML local.
    MlTunnelRemoteBind = "127.0.0.1:13003"
    MlTunnelLocalTarget = "127.0.0.1:3003"

    # Ruta local para guardar PID del túnel.
    MlTunnelPidFile = "$env:TEMP\\supernas-ml-tunnel.pid"

    # Servicio ML local en PC/WSL (usa GPU local).
    # Si está en true, el menú lo arranca al iniciar túnel y lo apaga al detener.
    MlAutoStartLocalService = $true
    MlAutoStopLocalService = $true
    MlLocalDockerContainer = "immich_ml_laptop"
    MlLocalListenPort = 3003
}
