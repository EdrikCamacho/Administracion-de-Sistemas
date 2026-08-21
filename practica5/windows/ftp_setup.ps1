###############################################################################
# ftp_setup.ps1
# Script principal - Practica 5: Automatizacion de Servidor FTP (Windows/IIS)
#
# Uso: ejecutar PowerShell como Administrador y correr .\ftp_setup.ps1
###############################################################################

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
. "$ScriptDir\lib\FtpFunctions.ps1"

function Mostrar-Menu {
    Write-Host ""
    Write-Host "==================================================="
    Write-Host "  Practica 5 - Automatizacion de Servidor FTP (IIS)"
    Write-Host "==================================================="
    Write-Host "1) Instalar rol IIS + FTP Server"
    Write-Host "2) Crear grupos y estructura base (general, grupos)"
    Write-Host "3) Configurar sitio FTP (anonimo + autenticacion + reglas)"
    Write-Host "4) Alta masiva de usuarios (n usuarios)"
    Write-Host "5) Cambiar de grupo a un usuario existente"
    Write-Host "6) Mostrar estado del sitio FTP"
    Write-Host "0) Salir"
    Write-Host "==================================================="
}

function Mostrar-Estado {
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Get-Website -Name $SitioFTP | Format-List Name, State, PhysicalPath, Bindings
}

Verificar-Admin

while ($true) {
    Mostrar-Menu
    $opcion = Read-Host "Selecciona una opcion"
    switch ($opcion) {
        "1" { Instalar-IISFTP }
        "2" { Configurar-EstructuraBase }
        "3" { Configurar-SitioFTP }
        "4" { Alta-MasivaUsuarios }
        "5" { Cambiar-GrupoUsuario }
        "6" { Mostrar-Estado }
        "0" { Write-Host "Saliendo..."; exit 0 }
        default { Write-Host "[ERROR] Opcion invalida." -ForegroundColor Red }
    }
}
