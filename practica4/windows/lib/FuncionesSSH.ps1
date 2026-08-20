###############################################################################
# FuncionesSSH.ps1
# Funciones para instalar y asegurar OpenSSH Server en el nodo Windows.
# Requiere: FuncionesComunes.ps1
###############################################################################

function Install-SshServer {
    Test-EsAdministrador
    $capacidad = Get-WindowsCapability -Online -Name OpenSSH.Server*
    if ($capacidad.State -eq "Installed") {
        Write-Host "[OK] OpenSSH Server ya está instalado."
    } else {
        Write-Host "[INFO] Instalando OpenSSH Server..."
        Add-WindowsCapability -Online -Name OpenSSH.Server~~~~0.0.1.0
    }
    Enable-ServicioWindows -Nombre "sshd"

    # PowerShell como shell por defecto para las sesiones SSH (opcional pero recomendado)
    New-ItemProperty -Path "HKLM:\SOFTWARE\OpenSSH" -Name DefaultShell `
        -Value "C:\Windows\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -PropertyType String -Force | Out-Null
}

function New-ReglaFirewallSSH {
    Test-EsAdministrador
    $regla = Get-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -ErrorAction SilentlyContinue

    if ($regla) {
        Write-Host "[OK] La regla de firewall para SSH (puerto 22) ya existe."
    } else {
        Write-Host "[INFO] Creando regla de firewall para el puerto 22/TCP..."
        New-NetFirewallRule -Name "OpenSSH-Server-In-TCP" -DisplayName "OpenSSH Server (sshd)" `
            -Enabled True -Direction Inbound -Protocol TCP -Action Allow -LocalPort 22
        Write-Host "[OK] Regla de firewall creada: puerto 22/TCP permitido."
    }
}

function Get-IpParaSSH {
    Write-Host "[INFO] Direcciones IP disponibles para conexión SSH:"
    Get-NetIPAddress -AddressFamily IPv4 |
        Where-Object { $_.IPAddress -ne "127.0.0.1" } |
        Select-Object IPAddress, InterfaceAlias
}