<#
###############################################################################
 Tarea 2 - Automatizacion y Gestion del Servidor DHCP (Windows)
 Universidad Autonoma de Sinaloa - FIM
 Rol: DHCP Server (modulo DhcpServer)
 Uso: Ejecutar PowerShell como Administrador -> .\dhcp_setup.ps1
###############################################################################
#>

$LogFile = "C:\dhcp_setup.log"

function Write-Log {
    param([string]$Message)
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Test-IPv4Format {
    param([string]$IPAddress)
    $pattern = '^((25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.){3}(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)$'
    return $IPAddress -match $pattern
}

function Read-ValidIP {
    param([string]$Prompt)
    while ($true) {
        $ip = Read-Host $Prompt
        if (Test-IPv4Format $ip) {
            return $ip
        } else {
            Write-Host "  -> Formato de IPv4 invalido. Intenta de nuevo (ej. 192.168.100.1)." -ForegroundColor Yellow
        }
    }
}

function Read-ValidInt {
    param([string]$Prompt)
    while ($true) {
        $val = Read-Host $Prompt
        if ($val -match '^\d+$') {
            return [int]$val
        } else {
            Write-Host "  -> Debe ser un numero entero." -ForegroundColor Yellow
        }
    }
}

# ----------------------------------------------------------------------------
# 1. Logica de instalacion idempotente
# ----------------------------------------------------------------------------
function Install-DhcpServerRole {
    $feature = Get-WindowsFeature -Name DHCP
    if ($feature.Installed) {
        Write-Log "El rol DHCP Server ya esta instalado. Se omite la instalacion."
    } else {
        Write-Log "Rol DHCP no encontrado. Iniciando instalacion desatendida..."
        Install-WindowsFeature -Name DHCP -IncludeManagementTools | Out-Null
        Write-Log "Instalacion del rol DHCP completada."
    }

    # Importar el modulo de administracion DHCP
    Import-Module DhcpServer -ErrorAction SilentlyContinue

    # Autorizar el servidor en el dominio si aplica (falla silenciosamente si no hay AD/DC)
    try {
        $hostname = [System.Net.Dns]::GetHostName()
        $auth = Get-DhcpServerInDC -ErrorAction SilentlyContinue
        if (-not ($auth | Where-Object { $_.DnsName -like "$hostname*" })) {
            Add-DhcpServerInDC -ErrorAction SilentlyContinue | Out-Null
            Write-Log "Servidor autorizado en el dominio (si aplica)."
        }
    } catch {
        Write-Log "Aviso: no se pudo autorizar en AD (entorno sin dominio); se continua en modo standalone."
    }
}

# ----------------------------------------------------------------------------
# 2. Orquestacion de configuracion dinamica
# ----------------------------------------------------------------------------
function Set-DhcpScopeConfig {
    Write-Host ""
    Write-Host "=== Configuracion interactiva del ambito DHCP ===" -ForegroundColor Cyan
    $ScopeName   = Read-Host "Nombre descriptivo del ambito (Scope)"
    $NetworkId   = Read-ValidIP "Direccion de red (ej. 192.168.100.0)"
    $StartRange  = Read-ValidIP "Rango inicial de asignacion"
    $EndRange    = Read-ValidIP "Rango final de asignacion"
    $Gateway     = Read-ValidIP "Puerta de enlace (Router/Gateway)"
    $DnsServer   = Read-ValidIP "Servidor DNS"
    $LeaseHours  = Read-ValidInt "Tiempo de concesion (Lease Time) en horas, ej. 24"
    $SubnetMask  = "255.255.255.0"
    $LeaseSpan   = New-TimeSpan -Hours $LeaseHours

    # Idempotencia: elimina el ambito si ya existe con ese ID de red, para recrearlo limpio
    $existing = Get-DhcpServerv4Scope -ScopeId $NetworkId -ErrorAction SilentlyContinue
    if ($existing) {
        Write-Log "Ya existe un ambito para ${NetworkId}. Se eliminara para recrearlo con los nuevos parametros."
        Remove-DhcpServerv4Scope -ScopeId $NetworkId -Force
    }

    Add-DhcpServerv4Scope -Name $ScopeName `
        -StartRange $StartRange -EndRange $EndRange `
        -SubnetMask $SubnetMask -LeaseDuration $LeaseSpan `
        -State Active

    Write-Log "Ambito '${ScopeName}' creado (${StartRange} - ${EndRange})."

    # Opciones de servidor: Router (003) y DNS (006)
    Set-DhcpServerv4OptionValue -ScopeId $NetworkId -Router $Gateway -DnsServer $DnsServer

    Write-Log "Opciones de Router (${Gateway}) y DNS (${DnsServer}) configuradas."

    Restart-Service DHCPServer
    Write-Log "Servicio DHCPServer reiniciado."
}

# ----------------------------------------------------------------------------
# 3. Modulo de monitoreo y validacion de estado
# ----------------------------------------------------------------------------
function Show-DhcpStatus {
    Write-Host ""
    Write-Host "=== Estado del servicio DHCPServer ===" -ForegroundColor Cyan
    Get-Service DHCPServer | Format-Table -AutoSize
    Write-Host "=== Ambitos configurados ===" -ForegroundColor Cyan
    Get-DhcpServerv4Scope | Format-Table -AutoSize
}

function Show-DhcpLeases {
    Write-Host ""
    Write-Host "=== Concesiones (leases) activas ===" -ForegroundColor Cyan
    $scopes = Get-DhcpServerv4Scope
    if (-not $scopes) {
        Write-Host "No hay ambitos configurados todavia."
        return
    }
    foreach ($scope in $scopes) {
        Write-Host "-- Ambito: $($scope.ScopeId) --"
        Get-DhcpServerv4Lease -ScopeId $scope.ScopeId |
            Select-Object IPAddress, HostName, ClientId, AddressState, LeaseExpiryTime |
            Format-Table -AutoSize
    }
}

function Show-DhcpMenu {
    while ($true) {
        Write-Host ""
        Write-Host "=== Modulo de Monitoreo DHCP ===" -ForegroundColor Cyan
        Write-Host "1) Ver estado del servicio y ambitos"
        Write-Host "2) Listar concesiones (leases) activas"
        Write-Host "3) Volver al menu principal"
        $opt = Read-Host "Selecciona una opcion"
        switch ($opt) {
            "1" { Show-DhcpStatus }
            "2" { Show-DhcpLeases }
            "3" { return }
            default { Write-Host "Opcion invalida." }
        }
    }
}

# ----------------------------------------------------------------------------
# Menu principal
# ----------------------------------------------------------------------------
function Show-MainMenu {
    while ($true) {
        Write-Host ""
        Write-Host "===== Gestion Automatizada de Servidor DHCP (Windows) =====" -ForegroundColor Green
        Write-Host "1) Instalar/verificar rol DHCP Server (idempotente)"
        Write-Host "2) Configurar ambito DHCP (interactivo)"
        Write-Host "3) Modulo de monitoreo"
        Write-Host "4) Salir"
        $opt = Read-Host "Selecciona una opcion"
        switch ($opt) {
            "1" { Install-DhcpServerRole }
            "2" { Set-DhcpScopeConfig }
            "3" { Show-DhcpMenu }
            "4" { return }
            default { Write-Host "Opcion invalida." }
        }
    }
}

# Verificar que se ejecuta como Administrador
$currentPrincipal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $currentPrincipal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Este script debe ejecutarse como Administrador." -ForegroundColor Red
    exit 1
}

Show-MainMenu