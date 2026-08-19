# tarea1_diagnostico.ps1
# Script de bienvenida / diagnostico inicial - Nodo Windows
# Muestra: nombre del equipo, IP actual y espacio en disco

Write-Host "==========================================" -ForegroundColor Cyan
Write-Host "   DIAGNOSTICO DE SISTEMA - $(Get-Date)"   -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan

Write-Host "`n--- Informacion del equipo ---" -ForegroundColor Yellow
Write-Host "Hostname: $env:COMPUTERNAME"
$os = Get-CimInstance Win32_OperatingSystem
Write-Host "Sistema Operativo: $($os.Caption)"

Write-Host "`n--- Direcciones IP ---" -ForegroundColor Yellow
Get-NetIPAddress -AddressFamily IPv4 |
    Where-Object { $_.IPAddress -ne "127.0.0.1" } |
    ForEach-Object {
        Write-Host "Interfaz $($_.InterfaceAlias): $($_.IPAddress)"
    }

Write-Host "`n--- Espacio en disco ---" -ForegroundColor Yellow
Get-CimInstance Win32_LogicalDisk -Filter "DriveType=3" |
    Select-Object DeviceID,
        @{N="TamanoGB";E={[math]::Round($_.Size/1GB,2)}},
        @{N="LibreGB";E={[math]::Round($_.FreeSpace/1GB,2)}},
        @{N="UsoPorc";E={[math]::Round((($_.Size-$_.FreeSpace)/$_.Size)*100,2)}} |
    Format-Table -AutoSize

Write-Host "`n--- Estado de red interna ---" -ForegroundColor Yellow
$redInterna = Get-NetIPAddress -AddressFamily IPv4 | Where-Object { $_.IPAddress -like "192.168.50.*" }
if ($redInterna) {
    Write-Host "Adaptador de Red Interna (red_sistemas): OK" -ForegroundColor Green
} else {
    Write-Host "ADVERTENCIA: No se detecto IP en el rango 192.168.50.0/24" -ForegroundColor Red
}

Write-Host "`n==========================================" -ForegroundColor Cyan
Write-Host "   FIN DEL DIAGNOSTICO" -ForegroundColor Cyan
Write-Host "==========================================" -ForegroundColor Cyan