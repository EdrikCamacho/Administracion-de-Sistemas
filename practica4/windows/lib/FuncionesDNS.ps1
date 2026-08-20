###############################################################################
# FuncionesDNS.ps1
# Lógica de la Tarea 3 (servidor DNS, dominio reprobados.com) migrada a
# funciones reutilizables. Requiere: FuncionesComunes.ps1
###############################################################################

function Install-DnsRole {
    Test-EsAdministrador
    Install-CaracteristicaWindows -Nombre "DNS"
}

function New-ZonaPrimariaDns {
    <#
        Uso: New-ZonaPrimariaDns -Dominio "reprobados.com"
    #>
    param([Parameter(Mandatory)][string]$Dominio)

    $zonaExistente = Get-DnsServerZone -Name $Dominio -ErrorAction SilentlyContinue
    if ($zonaExistente) {
        Write-Host "[OK] La zona '$Dominio' ya existe."
    } else {
        Add-DnsServerPrimaryZone -Name $Dominio -ZoneFile "$Dominio.dns"
        Write-Host "[OK] Zona primaria '$Dominio' creada."
    }
}

function Add-RegistroA {
    <#
        Uso: Add-RegistroA -Dominio "reprobados.com" -Host "www" -Ip "192.168.100.30"
        Host puede ser "@" (raíz) o "www"
    #>
    param(
        [Parameter(Mandatory)][string]$Dominio,
        [Parameter(Mandatory)][string]$Host,
        [Parameter(Mandatory)][string]$Ip
    )

    if (-not (Test-DireccionIP $Ip)) {
        Write-Host "[ERROR] IP inválida: $Ip" -ForegroundColor Red
        return
    }

    Add-DnsServerResourceRecordA -ZoneName $Dominio -Name $Host -IPv4Address $Ip
    Write-Host "[OK] Registro A agregado: $Host.$Dominio -> $Ip"
}

function Start-DnsServicio {
    Enable-ServicioWindows -Nombre "DNS"
}