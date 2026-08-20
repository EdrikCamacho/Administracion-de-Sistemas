###############################################################################
# Main.ps1 — Punto de entrada único del servidor Windows.
# Carga las bibliotecas de funciones y expone un menú de administración.
###############################################################################

$DirActual = Split-Path -Parent $MyInvocation.MyCommand.Path

. "$DirActual\lib\FuncionesComunes.ps1"
. "$DirActual\lib\FuncionesDHCP.ps1"
. "$DirActual\lib\FuncionesDNS.ps1"
. "$DirActual\lib\FuncionesSSH.ps1"

function Show-Menu {
    Clear-Host
    Write-Host "=========================================================="
    Write-Host "   Administración de Servicios de Red - Servidor Windows"
    Write-Host "=========================================================="
    Write-Host " 1) Instalar y habilitar OpenSSH Server"
    Write-Host " 2) Crear regla de firewall para SSH (puerto 22)"
    Write-Host " 3) Mostrar IP para conexión SSH"
    Write-Host " --------------------------------------------------------"
    Write-Host " 4) Instalar rol DHCP"
    Write-Host " 5) Configurar ámbito DHCP (192.168.100.0/24)"
    Write-Host " 6) Iniciar servicio DHCP"
    Write-Host " --------------------------------------------------------"
    Write-Host " 7) Instalar rol DNS"
    Write-Host " 8) Crear zona reprobados.com"
    Write-Host " 9) Iniciar servicio DNS"
    Write-Host " --------------------------------------------------------"
    Write-Host " 0) Salir"
    Write-Host "=========================================================="
}

Test-EsAdministrador

do {
    Show-Menu
    $opcion = Read-Host "Selecciona una opción"

    switch ($opcion) {
        "1" { Install-SshServer }
        "2" { New-ReglaFirewallSSH }
        "3" { Get-IpParaSSH }
        "4" { Install-DhcpRole }
        "5" { New-AmbitoDhcp -Nombre "Sistemas" -Red "192.168.100.0" -Mascara "255.255.255.0" `
                              -Inicio "192.168.100.50" -Fin "192.168.100.150" `
                              -Gateway "192.168.100.1" -Dns "192.168.100.10" }
        "6" { Start-DhcpServicio }
        "7" { Install-DnsRole }
        "8" { New-ZonaPrimariaDns -Dominio "reprobados.com"
              Add-RegistroA -Dominio "reprobados.com" -Host "@" -Ip "192.168.100.30"
              Add-RegistroA -Dominio "reprobados.com" -Host "www" -Ip "192.168.100.30" }
        "9" { Start-DnsServicio }
        "0" { Write-Host "Saliendo..." }
        default { Write-Host "[ERROR] Opción inválida." -ForegroundColor Red }
    }

    if ($opcion -ne "0") { Read-Host "`nPresiona ENTER para continuar" | Out-Null }

} while ($opcion -ne "0")