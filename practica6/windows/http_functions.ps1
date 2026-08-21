###############################################################################
# http_functions.ps1
# Librería de funciones - Práctica 6: Despliegue Dinámico de Servicios HTTP
# Multi-Versión (IIS obligatorio + Apache/Nginx opcionales) en Windows Server
#
# Este archivo NO se ejecuta solo. Debe cargarse con "." (dot-sourcing) desde
# main_http.ps1
###############################################################################

$PuertosReservados = @(20,21,22,23,25,53,67,68,111,123,135,139,389,445,3389)

function Write-Ok    { param($msg) Write-Host "[OK] $msg" -ForegroundColor Green }
function Write-Err2  { param($msg) Write-Host "[ERROR] $msg" -ForegroundColor Red }
function Write-Warn2 { param($msg) Write-Host "[AVISO] $msg" -ForegroundColor Yellow }
function Write-Info  { param($msg) Write-Host "[INFO] $msg" -ForegroundColor Cyan }

###############################################################################
# Test-Administrador
###############################################################################
function Test-Administrador {
    $actual = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal($actual)
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Err2 "Este script debe ejecutarse como Administrador."
        exit 1
    }
}

###############################################################################
# Test-EntradaValida <valor>
# Rechaza vacío y caracteres especiales peligrosos
###############################################################################
function Test-EntradaValida {
    param([string]$Valor)
    if ([string]::IsNullOrWhiteSpace($Valor)) { return $false }
    return [bool]($Valor -match '^[a-zA-Z0-9._-]+$')
}

###############################################################################
# Test-PuertoValido <puerto>
###############################################################################
function Test-PuertoValido {
    param([int]$Puerto)
    if ($Puerto -lt 1 -or $Puerto -gt 65535) {
        Write-Err2 "El puerto debe estar entre 1 y 65535."
        return $false
    }
    if ($PuertosReservados -contains $Puerto) {
        Write-Err2 "El puerto $Puerto está reservado (SSH/DNS/DHCP/RDP/etc.)."
        return $false
    }
    return $true
}

###############################################################################
# Test-PuertoOcupado <puerto>
###############################################################################
function Test-PuertoOcupado {
    param([int]$Puerto)
    $resultado = Test-NetConnection -ComputerName localhost -Port $Puerto -WarningAction SilentlyContinue
    return $resultado.TcpTestSucceeded
}

###############################################################################
# Read-PuertoValido [-PuertoActual <n>] -> retorna un puerto numérico válido
# Si el servicio que se va a (re)configurar YA está escuchando en el puerto
# indicado en -PuertoActual, se permite reingresar ese mismo puerto sin
# marcarlo como "ocupado" (evita falso positivo al reconfigurar un servicio
# ya instalado, detectado durante pruebas con IIS/Apache).
###############################################################################
function Read-PuertoValido {
    param([int]$PuertoActual = 0)

    while ($true) {
        $entrada = Read-Host "Ingrese el puerto de escucha deseado"
        if (-not ($entrada -match '^\d+$')) {
            Write-Err2 "El puerto debe ser numérico."
            continue
        }
        $puerto = [int]$entrada
        if (-not (Test-PuertoValido -Puerto $puerto)) { continue }

        if ($PuertoActual -gt 0 -and $puerto -eq $PuertoActual) {
            Write-Info "El puerto $puerto ya pertenece a este mismo servicio; se reconfigurará sin conflicto."
            return $puerto
        }

        if (Test-PuertoOcupado -Puerto $puerto) {
            Write-Err2 "El puerto $puerto ya está en uso. Elija otro."
            continue
        }
        return $puerto
    }
}

###############################################################################
# Get-PuertoActualIIS -> puerto donde el sitio YA está escuchando (0 si ninguno)
###############################################################################
function Get-PuertoActualIIS {
    param([string]$SitioWeb = "Default Web Site")
    $binding = Get-WebBinding -Name $SitioWeb -Protocol http -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($binding -and $binding.bindingInformation -match ':(\d+):') {
        return [int]$Matches[1]
    }
    return 0
}

###############################################################################
# Get-PuertoActualApache -> puerto donde Apache YA está escuchando (0 si ninguno)
###############################################################################
function Get-PuertoActualApache {
    $confPath = Get-ChildItem -Path "C:\Apache24" -Recurse -Filter "httpd.conf" -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notmatch '\\original$' } |
        Select-Object -First 1 -ExpandProperty FullName
    if ($confPath -and (Test-Path $confPath)) {
        $linea = Get-Content $confPath | Where-Object { $_ -match '^Listen (\d+)' } | Select-Object -First 1
        if ($linea -match '^Listen (\d+)') { return [int]$Matches[1] }
    }
    return 0
}

###############################################################################
# Get-PuertoActualNginx -> puerto donde Nginx YA está escuchando (0 si ninguno)
###############################################################################
function Get-PuertoActualNginx {
    $confPath = Get-ChildItem -Path "C:\tools" -Recurse -Filter "nginx.conf" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName
    if ($confPath -and (Test-Path $confPath)) {
        $linea = Get-Content $confPath | Where-Object { $_ -match 'listen\s+(\d+);' } | Select-Object -First 1
        if ($linea -match 'listen\s+(\d+);') { return [int]$Matches[1] }
    }
    return 0
}

###############################################################################
# Get-VersionesChocolatey <paquete> -> retorna la versión elegida o $null
# NOTA: el formato de salida de "choco info --all" puede variar según la
# versión de Chocolatey instalada; valide el parseo contra su entorno real.
###############################################################################
function Get-VersionesChocolatey {
    param([string]$Paquete)

    Write-Info "Consultando versiones disponibles de '$Paquete' vía Chocolatey..."
    # NOTA: desde Chocolatey CLI v2.0.0, "choco list" solo muestra paquetes
    # YA INSTALADOS localmente. Para consultar el repositorio remoto se debe
    # usar "choco search" (antes "choco list -s ..." en v1.x).
    $salida = choco search $Paquete --exact --all-versions --limit-output 2>$null

    $versiones = $salida | ForEach-Object { ($_ -split '\|')[1] } |
        Where-Object { $_ } | Sort-Object -Unique -Descending

    if (-not $versiones -or $versiones.Count -eq 0) {
        Write-Err2 "No se encontraron versiones para '$Paquete'."
        return $null
    }

    Write-Host "Versiones disponibles de $Paquete :"
    for ($i = 0; $i -lt $versiones.Count; $i++) {
        Write-Host "  $($i+1)) $($versiones[$i])"
    }
    Write-Host "  0) Cancelar"

    while ($true) {
        $opcion = Read-Host "Seleccione una versión [0-$($versiones.Count)]"
        if ($opcion -eq '0') { return $null }
        if ($opcion -match '^\d+$' -and [int]$opcion -ge 1 -and [int]$opcion -le $versiones.Count) {
            return $versiones[[int]$opcion - 1]
        }
        Write-Err2 "Opción inválida."
    }
}

###############################################################################
# New-IndexPage
###############################################################################
function New-IndexPage {
    param([string]$Servicio, [string]$Version, [int]$Puerto, [string]$RutaDestino)
    if (-not (Test-Path $RutaDestino)) { New-Item -ItemType Directory -Path $RutaDestino -Force | Out-Null }
    $html = @"
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>$Servicio</title></head>
<body>
    <h1>Servidor: $Servicio - Versión: $Version - Puerto: $Puerto</h1>
</body>
</html>
"@
    Set-Content -Path (Join-Path $RutaDestino "index.html") -Value $html -Encoding UTF8
}

###############################################################################
# Set-FirewallHttp <puerto>
# Abre SOLO el puerto elegido para HTTP y deshabilita las reglas de los
# puertos HTTP por defecto que no se usen.
###############################################################################
function Set-FirewallHttp {
    param([int]$Puerto)

    # IMPORTANTE: la Práctica 6 corre IIS + Apache + Nginx SIMULTÁNEAMENTE,
    # cada uno en su propio puerto. Por eso esta función solo AGREGA la
    # regla del puerto que se está configurando y jamás toca ni deshabilita
    # reglas de otros puertos — hacerlo rompería el acceso remoto a los
    # servicios que ya estaban corriendo (bug detectado y corregido durante
    # las pruebas: deshabilitar "puertos por defecto no usados" no puede
    # aplicarse de forma global cuando hay varios servicios activos a la vez).
    $reglaExistente = Get-NetFirewallRule -DisplayName "HTTP-Custom-$Puerto" -ErrorAction SilentlyContinue
    if (-not $reglaExistente) {
        New-NetFirewallRule -DisplayName "HTTP-Custom-$Puerto" -LocalPort $Puerto -Protocol TCP `
            -Action Allow -Direction Inbound | Out-Null
    }

    Write-Ok "Firewall configurado: el puerto $Puerto/tcp está permitido para HTTP (reglas de otros servicios activos no se modifican)."
}

###############################################################################
# Test-EncabezadosHttp <puerto>
###############################################################################
function Test-EncabezadosHttp {
    param([int]$Puerto)
    Write-Info "Resultado de 'Invoke-WebRequest -Method Head' contra el servicio local:"
    try {
        $resp = Invoke-WebRequest -Uri "http://localhost:$Puerto/" -Method Head -UseBasicParsing
        $resp.Headers | Format-Table -AutoSize
    } catch {
        Write-Err2 "No se pudo conectar al puerto $Puerto. $($_.Exception.Message)"
    }
}

###############################################################################
# ================== IIS ======================================================
###############################################################################

function Install-IISRole {
    Write-Info "Instalando IIS (obligatorio)..."
    Install-WindowsFeature -Name Web-Server -IncludeManagementTools | Out-Null
    Import-Module WebAdministration -ErrorAction SilentlyContinue
    Write-Ok "IIS instalado."
}

function Set-IISPuerto {
    param([int]$Puerto, [string]$SitioWeb = "Default Web Site")
    Get-WebBinding -Name $SitioWeb | Remove-WebBinding
    New-WebBinding -Name $SitioWeb -Protocol http -Port $Puerto -IPAddress "*"
    Write-Ok "IIS configurado para escuchar en el puerto $Puerto."
}

function Protect-IISHeaders {
    param([string]$SitioWeb = "Default Web Site")

    # Elimina el header X-Powered-By
    Clear-WebConfiguration -pspath "IIS:\Sites\$SitioWeb" `
        -filter "system.webServer/httpProtocol/customHeaders/add[@name='X-Powered-By']" `
        -ErrorAction SilentlyContinue

    # Oculta la versión exacta del servidor (Request Filtering)
    Set-WebConfigurationProperty -pspath "IIS:\Sites\$SitioWeb" `
        -filter "system.webServer/security/requestFiltering" `
        -name "removeServerHeader" -value "True"

    Write-Ok "Encabezados de versión ocultados en IIS."
}

function Add-IISSecurityHeaders {
    param([string]$SitioWeb = "Default Web Site")

    $headers = @{ 'X-Frame-Options' = 'SAMEORIGIN'; 'X-Content-Type-Options' = 'nosniff' }
    foreach ($nombre in $headers.Keys) {
        $existe = Get-WebConfigurationProperty -pspath "IIS:\Sites\$SitioWeb" `
            -filter "system.webServer/httpProtocol/customHeaders/add[@name='$nombre']" `
            -name "name" -ErrorAction SilentlyContinue
        if (-not $existe) {
            Add-WebConfigurationProperty -pspath "IIS:\Sites\$SitioWeb" `
                -filter "system.webServer/httpProtocol/customHeaders" -name "." `
                -value @{name=$nombre; value=$headers[$nombre]} -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Encabezados de seguridad agregados en IIS."
}

function Restrict-IISMethods {
    param([string]$SitioWeb = "Default Web Site")
    foreach ($metodo in @('TRACE','TRACK','DELETE','PUT')) {
        $existe = Get-WebConfigurationProperty -pspath "IIS:\Sites\$SitioWeb" `
            -filter "system.webServer/security/requestFiltering/verbs/add[@verb='$metodo']" `
            -name "verb" -ErrorAction SilentlyContinue
        if (-not $existe) {
            Add-WebConfigurationProperty -pspath "IIS:\Sites\$SitioWeb" `
                -filter "system.webServer/security/requestFiltering/verbs" -name "." `
                -value @{verb=$metodo; allowed='false'} -ErrorAction SilentlyContinue
        }
    }
    Write-Ok "Métodos HTTP peligrosos (TRACE/TRACK/DELETE/PUT) bloqueados en IIS."
}

###############################################################################
# ================== APACHE (Windows, vía Chocolatey) ========================
###############################################################################

function Install-ApacheWindows {
    param([string]$Version, [int]$Puerto)

    # El paquete apache-httpd de Chocolatey usa el puerto 8080 POR DEFECTO
    # y su propio instalador aborta si ese puerto está ocupado (p. ej. por
    # IIS). Por eso el puerto se pasa obligatoriamente en /port desde la
    # instalación, no se edita después.
    #
    # NOTA (defecto conocido del paquete): /installLocation:C:\Apache24 NO
    # deja httpd.conf en C:\Apache24\conf, sino en C:\Apache24\Apache24\conf
    # (crea una subcarpeta con el mismo nombre). Por eso la ruta real del
    # conf y del htdocs se BUSCA después de instalar, en vez de asumirse.
    $installDir = "C:\Apache24"

    if (Get-Service -Name "Apache*" -ErrorAction SilentlyContinue) {
        Write-Warn2 "Apache ya parece estar instalado. Se omite instalación."
    } else {
        Write-Info "Instalando Apache $Version vía Chocolatey (modo silencioso, puerto $Puerto)..."
        choco install apache-httpd --version=$Version -y --no-progress `
            --params "`"/installLocation:$installDir /port:$Puerto`"" | Out-Null
    }

    $confPath = Get-ChildItem -Path $installDir -Recurse -Filter "httpd.conf" -ErrorAction SilentlyContinue |
        Where-Object { $_.DirectoryName -notmatch '\\original$' } |
        Select-Object -First 1 -ExpandProperty FullName

    if ($confPath) {
        $raizReal = Split-Path (Split-Path $confPath -Parent) -Parent
        Write-Info "httpd.conf localizado en: $confPath"

        (Get-Content $confPath) -replace '^Listen \d+', "Listen $Puerto" |
            Set-Content $confPath

        # Asegura que mod_headers esté cargado (requerido para los headers de seguridad)
        $lineasConf = Get-Content $confPath
        if ($lineasConf -match '^\s*#\s*LoadModule\s+headers_module') {
            $lineasConf = $lineasConf -replace '^\s*#\s*(LoadModule\s+headers_module.*)', '$1'
            Set-Content -Path $confPath -Value $lineasConf
        } elseif (-not ($lineasConf -match '^\s*LoadModule\s+headers_module')) {
            Add-Content $confPath "LoadModule headers_module modules/mod_headers.so"
        }

        # Hardening idempotente: se agrega UNA sola vez (evita duplicar el
        # bloque en cada reconfiguración del mismo servicio)
        if (-not (Select-String -Path $confPath -Pattern '^ServerTokens' -Quiet -ErrorAction SilentlyContinue)) {
            Add-Content $confPath @"

ServerTokens Prod
ServerSignature Off
TraceEnable off
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
<Location "/">
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Location>
"@
        }

        New-IndexPage -Servicio "Apache" -Version $Version -Puerto $Puerto -RutaDestino (Join-Path $raizReal "htdocs")

        Restart-Service -Name "Apache" -ErrorAction SilentlyContinue
    } else {
        Write-Err2 "No se pudo localizar httpd.conf bajo $installDir. Revise la instalación manualmente."
    }

    Set-FirewallHttp -Puerto $Puerto
    Write-Ok "Apache Windows instalado y configurado en el puerto $Puerto."
}

###############################################################################
# ================== NGINX (Windows, vía Chocolatey) ==========================
###############################################################################

function Install-NginxWindows {
    param([string]$Version, [int]$Puerto)

    # El paquete "nginx" de Chocolatey SOLO extrae los binarios: no crea
    # servicio de Windows ni arranca el proceso (a diferencia de Apache/IIS).
    # Se detectó al probar (Invoke-WebRequest no conectaba pese a que el
    # script "terminaba bien"). Se registra con NSSM como servicio para que
    # quede persistente y administrable igual que los demás servicios.
    if (Get-Service -Name "nginx" -ErrorAction SilentlyContinue) {
        Write-Warn2 "Nginx ya está registrado como servicio. Se omite instalación."
    } else {
        Write-Info "Instalando Nginx $Version vía Chocolatey (modo silencioso)..."
        choco install nginx --version=$Version -y --no-progress | Out-Null

        if (-not (Get-Command nssm -ErrorAction SilentlyContinue)) {
            Write-Info "Instalando NSSM para administrar Nginx como servicio de Windows..."
            choco install nssm -y --no-progress | Out-Null
        }
    }

    $nginxExe = Get-ChildItem -Path "C:\tools" -Recurse -Filter "nginx.exe" -ErrorAction SilentlyContinue |
        Select-Object -First 1 -ExpandProperty FullName

    if (-not $nginxExe) {
        Write-Err2 "No se pudo localizar nginx.exe bajo C:\tools. Revise la instalación manualmente."
        return
    }

    $nginxDir = Split-Path $nginxExe -Parent
    $confPath = Join-Path $nginxDir "conf\nginx.conf"
    Write-Info "Nginx localizado en: $nginxDir"

    if (Test-Path $confPath) {
        $lineas = Get-Content $confPath

        # Limpia cualquier "server_tokens" suelto fuera de bloque que haya
        # quedado de una corrida anterior (causaba "directive is not allowed
        # here" y nginx.exe no arrancaba).
        $lineas = $lineas | Where-Object { $_.Trim() -ne 'server_tokens off;' }

        # Cambia el puerto en las directivas "listen" activas
        $lineas = $lineas -replace 'listen\s+\d+;', "listen $Puerto;"

        $yaTieneHeaders = ($lineas -join "`n") -match 'X-Frame-Options'

        # Inserta server_tokens off; DENTRO del bloque http {, y los headers
        # de seguridad + bloqueo de métodos DENTRO del primer bloque server {
        # (son directivas válidas solo dentro de esos bloques, nunca a nivel
        # de archivo — error real detectado durante las pruebas).
        $resultado = New-Object System.Collections.Generic.List[string]
        $serverInsertado = $false
        foreach ($linea in $lineas) {
            $resultado.Add($linea)
            if ($linea -match '^\s*http\s*\{') {
                $resultado.Add('    server_tokens off;')
            }
            if (-not $yaTieneHeaders -and -not $serverInsertado -and $linea -match '^\s*server\s*\{') {
                $resultado.Add('        add_header X-Frame-Options "SAMEORIGIN" always;')
                $resultado.Add('        add_header X-Content-Type-Options "nosniff" always;')
                $resultado.Add('        if ($request_method !~ ^(GET|HEAD|POST)$) { return 405; }')
                $serverInsertado = $true
            }
        }
        Set-Content -Path $confPath -Value $resultado
    } else {
        Write-Err2 "No se encontró nginx.conf en $confPath."
        return
    }

    Push-Location $nginxDir
    $resultadoTest = & ".\nginx.exe" -t 2>&1 | Out-String
    Pop-Location
    if ($resultadoTest -notmatch 'test is successful') {
        Write-Err2 "La configuración de Nginx sigue siendo inválida:"
        Write-Host $resultadoTest
        return
    }

    New-IndexPage -Servicio "Nginx" -Version $Version -Puerto $Puerto -RutaDestino (Join-Path $nginxDir "html")

    if (-not (Get-Service -Name "nginx" -ErrorAction SilentlyContinue)) {
        nssm install nginx $nginxExe | Out-Null
        nssm set nginx Start SERVICE_AUTO_START | Out-Null
    }
    # Se fuerza SIEMPRE, no solo en la instalación: si un intento anterior
    # registró el servicio sin este valor, arrancaba con el directorio de
    # trabajo equivocado y nginx no encontraba su propio nginx.conf.
    nssm set nginx AppDirectory $nginxDir | Out-Null

    Restart-Service -Name "nginx" -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2

    Set-FirewallHttp -Puerto $Puerto
    Write-Ok "Nginx Windows instalado, registrado como servicio y escuchando en el puerto $Puerto."
}
