###############################################################################
# FuncionesDHCP.ps1
# Lógica de la Tarea 2 (servidor DHCP) migrada a funciones reutilizables.
# Requiere: FuncionesComunes.ps1
###############################################################################

function Install-DhcpRole {
    Test-EsAdministrador
    Install-CaracteristicaWindows -Nombre "DHCP"
}

function New-AmbitoDhcp {
    <#
        Uso: New-AmbitoDhcp -Nombre "Sistemas" -Red "192.168.100.0" -Mascara "255.255.255.0" `
                             -Inicio "192.168.100.50" -Fin "192.168.100.150" `
                             -Gateway "192.168.100.1" -Dns "192.168.100.10"
    #>
    param(
        [Parameter(Mandatory)][string]$Nombre,
        [Parameter(Mandatory)][string]$Red,
        [Parameter(Mandatory)][string]$Mascara,
        [Parameter(Mandatory)][string]$Inicio,
        [Parameter(Mandatory)][string]$Fin,
        [Parameter(Mandatory)][string]$Gateway,
        [Parameter(Mandatory)][string]$Dns
    )

    foreach ($ip in @($Red, $Inicio, $Fin, $Gateway, $Dns)) {
        if (-not (Test-DireccionIP $ip)) {
            Write-Host "[ERROR] IP inválida: $ip" -ForegroundColor Red
            return
        }
    }

    Add-DhcpServerv4Scope -Name $Nombre -StartRange $Inicio -EndRange $Fin `
        -SubnetMask $Mascara -State Active

    Set-DhcpServerv4OptionValue -ScopeId $Red -Router $Gateway -DnsServer $Dns

    Write-Host "[OK] Ámbito DHCP '$Nombre' creado ($Inicio - $Fin)."
}

function Start-DhcpServicio {
    Enable-ServicioWindows -Nombre "DHCPServer"
}