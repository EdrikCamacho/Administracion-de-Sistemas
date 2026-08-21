###############################################################################
# main_http.ps1 - Práctica 6
# Menú principal de despliegue dinámico de servicios HTTP (Windows Server)
# Uso: ejecutar en PowerShell como Administrador, vía sesión SSH remota
###############################################################################

. "$PSScriptRoot\http_functions.ps1"

function Show-Menu {
    Write-Host ""
    Write-Host "======================================"
    Write-Host " Práctica 6 - Despliegue HTTP Dinámico"
    Write-Host "======================================"
    Write-Host "1) Configurar IIS (obligatorio)"
    Write-Host "2) Instalar / configurar Apache (Windows)"
    Write-Host "3) Instalar / configurar Nginx (Windows)"
    Write-Host "4) Salir"
    Write-Host "--------------------------------------"
}

function Invoke-FlujoIIS {
    Install-IISRole
    $puertoActual = Get-PuertoActualIIS
    $puerto = Read-PuertoValido -PuertoActual $puertoActual
    Set-IISPuerto -Puerto $puerto
    Protect-IISHeaders
    Add-IISSecurityHeaders
    Restrict-IISMethods
    New-IndexPage -Servicio "IIS" -Version "10 (Windows Server 2022)" -Puerto $puerto -RutaDestino "C:\inetpub\wwwroot"
    Set-FirewallHttp -Puerto $puerto
    Test-EncabezadosHttp -Puerto $puerto
}

function Invoke-FlujoApache {
    $puertoActual = Get-PuertoActualApache
    $version = Get-VersionesChocolatey -Paquete "apache-httpd"
    if (-not $version) { return }
    $puerto = Read-PuertoValido -PuertoActual $puertoActual
    Install-ApacheWindows -Version $version -Puerto $puerto
    Test-EncabezadosHttp -Puerto $puerto
}

function Invoke-FlujoNginx {
    $puertoActual = Get-PuertoActualNginx
    $version = Get-VersionesChocolatey -Paquete "nginx"
    if (-not $version) { return }
    $puerto = Read-PuertoValido -PuertoActual $puertoActual
    Install-NginxWindows -Version $version -Puerto $puerto
    Test-EncabezadosHttp -Puerto $puerto
}

Test-Administrador

do {
    Show-Menu
    $opcion = Read-Host "Seleccione una opción"
    switch ($opcion) {
        '1' { Invoke-FlujoIIS }
        '2' { Invoke-FlujoApache }
        '3' { Invoke-FlujoNginx }
        '4' { Write-Info "Saliendo..." }
        default { Write-Err2 "Opción inválida." }
    }
} while ($opcion -ne '4')
