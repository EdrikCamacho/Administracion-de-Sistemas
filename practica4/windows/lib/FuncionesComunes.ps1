###############################################################################
# FuncionesComunes.ps1
# Funciones genéricas reutilizadas por todos los módulos (DHCP, DNS, SSH).
# Se carga con ". .\FuncionesComunes.ps1" desde Main.ps1
###############################################################################

function Test-EsAdministrador {
    <#
        Aborta la ejecución si PowerShell no corre como Administrador.
    #>
    $esAdmin = ([Security.Principal.WindowsPrincipal] `
        [Security.Principal.WindowsIdentity]::GetCurrent()
        ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)

    if (-not $esAdmin) {
        Write-Host "[ERROR] Este script debe ejecutarse como Administrador." -ForegroundColor Red
        exit 1
    }
}

function Install-CaracteristicaWindows {
    <#
        Instala una característica/rol de Windows solo si no está instalada.
        Uso: Install-CaracteristicaWindows -Nombre "DNS"
    #>
    param([Parameter(Mandatory)][string]$Nombre)

    $feature = Get-WindowsFeature -Name $Nombre
    if ($feature.Installed) {
        Write-Host "[OK] La característica '$Nombre' ya está instalada."
    } else {
        Write-Host "[INFO] Instalando característica '$Nombre'..."
        Install-WindowsFeature -Name $Nombre -IncludeManagementTools
    }
}

function Test-DireccionIP {
    <#
        Valida el formato de una IPv4. Devuelve $true/$false.
        Uso: if (Test-DireccionIP "192.168.100.20") { ... }
    #>
    param([Parameter(Mandatory)][string]$Ip)

    $resultado = $null
    return [System.Net.IPAddress]::TryParse($Ip, [ref]$resultado) -and $Ip -match '^\d{1,3}(\.\d{1,3}){3}$'
}

function Enable-ServicioWindows {
    <#
        Habilita e inicia un servicio de Windows, verificando su estado final.
        Uso: Enable-ServicioWindows -Nombre "sshd"
    #>
    param([Parameter(Mandatory)][string]$Nombre)

    Write-Host "[INFO] Configurando '$Nombre' para inicio automático..."
    Set-Service -Name $Nombre -StartupType Automatic
    Start-Service -Name $Nombre

    $estado = (Get-Service -Name $Nombre).Status
    if ($estado -eq "Running") {
        Write-Host "[OK] '$Nombre' está en ejecución y habilitado en el arranque."
    } else {
        Write-Host "[ERROR] '$Nombre' no pudo iniciar. Estado: $estado" -ForegroundColor Red
    }
}