#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Tarea 3 - Automatización del Servidor DNS (Windows DNS Server)
    Materia: Sistemas - Prof. Herman Geovany Ayala Zuñiga

.EXAMPLE
    .\dns_setup_windows.ps1 -Domain reprobados.com -RecordIP 192.168.100.30

.NOTES
    Entorno de referencia (mismo usado en Tarea 2 - DHCP):
    red_sistemas: 192.168.100.0/24
    Srv-Win-Sistemas: 192.168.100.20 (este servidor)
    Srv-Linux-Sistemas: 192.168.100.10
    Cliente Mint: 192.168.100.30 (o rango DHCP .50-.150)
#>

param(
    [string]$Domain = "reprobados.com",
    [string]$RecordIP = "",
    [string]$WwwIP = ""
)

$ErrorActionPreference = "Stop"
$LogFile = "C:\Tarea3_DNS_Setup.log"

function Write-Log {
    param([string]$Message, [string]$Level = "INFO")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $line = "[$timestamp][$Level] $Message"
    Write-Host $line
    Add-Content -Path $LogFile -Value $line
}

function Test-ValidIP {
    param([string]$IPAddress)
    return ($IPAddress -as [System.Net.IPAddress]) -ne $null
}

function Get-InputIfEmpty {
    param([string]$CurrentValue, [string]$Prompt, [string]$DefaultValue)
    if ([string]::IsNullOrWhiteSpace($CurrentValue)) {
        $input = Read-Host "$Prompt [$DefaultValue]"
        if ([string]::IsNullOrWhiteSpace($input)) { $input = $DefaultValue }
        while (-not (Test-ValidIP $input)) {
            Write-Host "IP invalida: $input" -ForegroundColor Red
            $input = Read-Host "$Prompt [$DefaultValue]"
            if ([string]::IsNullOrWhiteSpace($input)) { $input = $DefaultValue }
        }
        return $input
    }
    return $CurrentValue
}

# ------------------------- Verificación de IP fija del servidor -----------------
function Confirm-StaticIP {
    Write-Log "Verificando configuracion de IP fija..."

    $adapters = Get-NetAdapter | Where-Object { $_.Status -eq "Up" }
    $staticAdapter = $null
    $staticIP = $null

    # Recorre TODOS los adaptadores activos y busca uno que YA tenga
    # IP configurada manualmente (Dhcp -eq "Disabled"), sin asumir que
    # el primero de la lista es el relevante (en este entorno suele
    # aparecer primero el adaptador NAT, no el de red_sistemas).
    foreach ($adapter in $adapters) {
        $ipIface = Get-NetIPInterface -InterfaceIndex $adapter.ifIndex -AddressFamily IPv4 -ErrorAction SilentlyContinue
        if ($null -eq $ipIface) { continue }
        if ($ipIface.Dhcp -eq "Disabled") {
            $cfg = Get-NetIPConfiguration -InterfaceIndex $adapter.ifIndex -ErrorAction SilentlyContinue
            $addr = $cfg.IPv4Address.IPAddress
            if (-not [string]::IsNullOrWhiteSpace($addr)) {
                $staticAdapter = $adapter
                $staticIP = $addr
                break
            }
        }
    }

    if ($staticIP) {
        Write-Log "El servidor ya tiene IP fija: $staticIP en $($staticAdapter.Name)." "OK"
        return $staticIP
    }

    # Ningún adaptador tiene IP estática: pedir datos al usuario.
    # Se pide también qué adaptador usar, mostrando la lista de activos.
    Write-Log "No se detecto ningun adaptador con IP fija configurada." "WARN"
    Write-Host "Adaptadores activos disponibles:"
    $adapters | ForEach-Object { Write-Host "  - $($_.Name) (ifIndex $($_.ifIndex))" }
    $targetName = Read-Host "Nombre del adaptador de red_sistemas a configurar [Ethernet1]"
    if ([string]::IsNullOrWhiteSpace($targetName)) { $targetName = "Ethernet1" }
    $adapter = Get-NetAdapter -Name $targetName

    $newIP = Get-InputIfEmpty "" "Ingresa IP fija para $($adapter.Name)" "192.168.100.20"
    $prefix = Read-Host "Prefijo CIDR [24]"
    if ([string]::IsNullOrWhiteSpace($prefix)) { $prefix = 24 }
    $gateway = Read-Host "Gateway [192.168.100.1]"
    if ([string]::IsNullOrWhiteSpace($gateway)) { $gateway = "192.168.100.1" }

    Remove-NetIPAddress -InterfaceIndex $adapter.ifIndex -Confirm:$false -ErrorAction SilentlyContinue
    Set-NetIPInterface -InterfaceIndex $adapter.ifIndex -Dhcp Disabled
    New-NetIPAddress -InterfaceIndex $adapter.ifIndex -IPAddress $newIP -PrefixLength $prefix -DefaultGateway $gateway
    Set-DnsClientServerAddress -InterfaceIndex $adapter.ifIndex -ServerAddresses ("127.0.0.1")

    Write-Log "IP fija $newIP/$prefix aplicada en $($adapter.Name)." "OK"
    return $newIP
}

# ------------------------- Instalación idempotente del rol DNS -------------------
function Install-DnsRole {
    $feature = Get-WindowsFeature -Name DNS
    if ($feature.InstallState -eq "Installed") {
        Write-Log "El rol DNS Server ya esta instalado. Se omite instalacion." "OK"
    }
    else {
        Write-Log "Instalando rol DNS Server..."
        Install-WindowsFeature -Name DNS -IncludeManagementTools
        Write-Log "Rol DNS Server instalado." "OK"
    }

    $svc = Get-Service -Name DNS
    if ($svc.Status -ne "Running") {
        Start-Service DNS
        Write-Log "Servicio DNS iniciado." "OK"
    }
    else {
        Write-Log "El servicio DNS ya esta activo." "OK"
    }
}

# ------------------------- Configuración de zona y registros ----------------------
function Set-DnsZoneAndRecords {
    param([string]$Domain, [string]$RecordIP, [string]$WwwIP)

    $existingZone = Get-DnsServerZone -Name $Domain -ErrorAction SilentlyContinue
    if ($existingZone) {
        Write-Log "La zona $Domain ya existe. Se omite creacion de zona." "OK"
    }
    else {
        Write-Log "Creando zona primaria $Domain..."
        Add-DnsServerPrimaryZone -Name $Domain -ZoneFile "$Domain.dns"
        Write-Log "Zona $Domain creada." "OK"
    }

    # Registro A raiz (@)
    $rootRecord = Get-DnsServerResourceRecord -ZoneName $Domain -Name "@" -RRType A -ErrorAction SilentlyContinue
    if ($rootRecord) {
        Write-Log "Registro A para $Domain ya existe. Se elimina para actualizar." "WARN"
        Remove-DnsServerResourceRecord -ZoneName $Domain -Name "@" -RRType A -Force
    }
    Add-DnsServerResourceRecordA -ZoneName $Domain -Name "@" -IPv4Address $RecordIP
    Write-Log "Registro A: $Domain -> $RecordIP" "OK"

    # Registro A/CNAME para www
    $wwwRecord = Get-DnsServerResourceRecord -ZoneName $Domain -Name "www" -RRType A -ErrorAction SilentlyContinue
    if ($wwwRecord) {
        Write-Log "Registro A para www.$Domain ya existe. Se elimina para actualizar." "WARN"
        Remove-DnsServerResourceRecord -ZoneName $Domain -Name "www" -RRType A -Force
    }
    Add-DnsServerResourceRecordA -ZoneName $Domain -Name "www" -IPv4Address $WwwIP
    Write-Log "Registro A: www.$Domain -> $WwwIP" "OK"
}

# ------------------------- Prueba de resolución -----------------------------------
function Test-DnsResolution {
    param([string]$Domain)
    Write-Log "Probando resolucion local..."
    Restart-Service DNS
    Start-Sleep -Seconds 2

    try {
        $result = Resolve-DnsName -Name $Domain -Server 127.0.0.1 -Type A
        Write-Log "Resolucion de $Domain -> $($result.IPAddress)" "OK"
    }
    catch {
        Write-Log "Fallo la resolucion de $Domain : $_" "ERROR"
    }

    try {
        $resultWww = Resolve-DnsName -Name "www.$Domain" -Server 127.0.0.1 -Type A
        Write-Log "Resolucion de www.$Domain -> $($resultWww.IPAddress)" "OK"
    }
    catch {
        Write-Log "Fallo la resolucion de www.$Domain : $_" "ERROR"
    }
}

# ============================== MAIN ==============================
Write-Host "======================================================"
Write-Host " Tarea 3 - Automatizacion de Servidor DNS (Windows)"
Write-Host "======================================================"

$serverIP = Confirm-StaticIP
$RecordIP = Get-InputIfEmpty $RecordIP "IP a la que apuntara $Domain (registro A)" "192.168.100.30"
$WwwIP = Get-InputIfEmpty $WwwIP "IP a la que apuntara www.$Domain" $RecordIP

Install-DnsRole
Set-DnsZoneAndRecords -Domain $Domain -RecordIP $RecordIP -WwwIP $WwwIP
Test-DnsResolution -Domain $Domain

Write-Host "======================================================"
Write-Log "Configuracion de DNS finalizada. Log en $LogFile" "OK"
Write-Host "======================================================"