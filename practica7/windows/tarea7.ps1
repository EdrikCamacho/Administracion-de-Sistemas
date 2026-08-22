# ============================================================================
# TAREA 7 - ORQUESTADOR HÍBRIDO E INFRAESTRUCTURA DE DESPLIEGUE SEGURO (WINDOWS)
# Este script es SOLO el menú: toda la lógica vive en tarea7_functions.ps1
# ============================================================================

$DirActual = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$DirActual\tarea7_functions.ps1"

$global:resumenInstalaciones = @()
$global:Dominio = "www.reprobados.com"
$global:FtpServer = "192.168.100.20"   # IIS-FTP local (nodo Windows Server, red_sistemas)
$global:FtpUser = "anonymous"
$global:FtpPass = "anonymous"
$global:ResumenArchivo = "C:\tarea7_resumen.log"

function Menu-Principal {
    while ($true) {
        Write-Host "`n==========================================" -ForegroundColor Blue
        Write-Host "  TAREA 7 - DESPLIEGUE SEGURO (WINDOWS)" -ForegroundColor Blue
        Write-Host "==========================================" -ForegroundColor Blue
        Write-Host "1) Instalar IIS Web (SSL Dinámico)"
        Write-Host "2) Instalar IIS FTP (SSL Dinámico)"
        Write-Host "3) Instalar Apache (Descarga FTP/Web + SSL)"
        Write-Host "4) Instalar Nginx (Descarga FTP/Web + SSL)"
        Write-Host "5) Generar firmas SHA256 en el repositorio local"
        Write-Host "6) Ver resumen general de la sesión"
        Write-Host "7) Salir"
        $opcion = Read-Host "Selecciona una opción [1-7]"

        switch ($opcion) {
            "1" { Instalar-IIS-Web-Hibrido }
            "2" { Instalar-IIS-FTP-Hibrido }
            "3" { Instalar-Apache-Hibrido }
            "4" { Instalar-Nginx-Hibrido }
            "5" { Administrar-FirmasRepositorio }
            "6" {
                Write-Host "`n########## RESUMEN GENERAL DE LA PRÁCTICA 7 ##########" -ForegroundColor Blue
                if ((Test-Path $global:ResumenArchivo) -and (Get-Content $global:ResumenArchivo).Count -gt 0) {
                    Get-Content $global:ResumenArchivo | ForEach-Object { Write-Host "- $_" -ForegroundColor Green }
                }
                else {
                    Write-Host "Aún no se ha instalado ningún servicio (ni en esta sesión ni en sesiones anteriores)." -ForegroundColor Yellow
                }
                Write-Host "#######################################################" -ForegroundColor Blue
            }
            "7" { return }
            default { Write-Host "Opción inválida." -ForegroundColor Red }
        }
    }
}

Menu-Principal
