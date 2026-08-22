# ============================================================================
# TAREA 7 - LIBRERÍA DE FUNCIONES (WINDOWS)
# Infraestructura de Despliegue Seguro e Instalación Híbrida (FTP/Web)
# Refactorización modular: este archivo SOLO contiene funciones.
# El menú principal (tarea7.ps1) es el único que las invoca.
#
# NOTA: fixes aplicados durante las pruebas en vivo:
#  - IIS Web: Liberar-Puertos-Web detiene W3SVC/WAS al limpiar el entorno
#    (y también se llama desde Apache/Nginx), pero nada los reactivaba.
#    Se agregó Start-Service WAS/W3SVC dentro de Instalar-IIS-Web-Hibrido
#    para que el sitio quede realmente arriba (antes: proceso FAIL, puerto
#    CERRADO aunque el sitio apareciera "Started" en Get-Website).
# ============================================================================

# ------------------------------------------------------------------
# 0. RESUMEN Y VALIDACIONES
# ------------------------------------------------------------------
function Escribir-Resumen {
    param([string]$mensaje)
    $global:resumenInstalaciones += $mensaje
    Write-Host $mensaje -ForegroundColor Magenta
    # FIX (igual que en Linux): se guarda también en disco para que el
    # resumen sobreviva a cerrar y reabrir PowerShell.
    if ($global:ResumenArchivo) {
        if (-not (Test-Path $global:ResumenArchivo)) { New-Item -ItemType File -Path $global:ResumenArchivo -Force | Out-Null }
        $tag = if ($mensaje -match '^\[([A-Z \-]+)\]') { $Matches[1] } else { $null }
        if ($tag) {
            $lineasPrevias = Get-Content $global:ResumenArchivo -ErrorAction SilentlyContinue | Where-Object { $_ -notmatch "^\[$tag\]" }
            $lineasPrevias + $mensaje | Set-Content -Path $global:ResumenArchivo
        } else {
            Add-Content -Path $global:ResumenArchivo -Value $mensaje
        }
    }
}

function Validar-Puerto {
    param ([string]$Puerto)
    if ([string]::IsNullOrWhiteSpace($Puerto) -or $Puerto -notmatch "^\d+$") {
        Write-Host "[X] Error: El puerto debe ser un número." -ForegroundColor Red
        return $false
    }
    $PuertoInt = [int]$Puerto
    if ($PuertoInt -le 0 -or $PuertoInt -gt 65535) {
        Write-Host "[X] Error: El puerto debe estar entre 1 y 65535." -ForegroundColor Red
        return $false
    }
    $ocupado = Get-NetTCPConnection -LocalPort $PuertoInt -State Listen -ErrorAction SilentlyContinue
    if ($ocupado) {
        Write-Host "[X] Error: El puerto $PuertoInt ya está en uso." -ForegroundColor Red
        return $false
    }
    return $true
}

function Pedir-Puerto {
    param([string]$Prompt)
    while ($true) {
        $p = Read-Host $Prompt
        if (Validar-Puerto -Puerto $p) { return [int]$p }
    }
}

function Liberar-Puertos-Web {
    Write-Host "Iniciando limpieza profunda del entorno..." -ForegroundColor Yellow
    taskkill /F /IM httpd.exe /T 2>$null
    taskkill /F /IM nginx.exe /T 2>$null

    Stop-Service -Name "W3SVC" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "WAS" -Force -ErrorAction SilentlyContinue
    Stop-Service -Name "apache" -Force -ErrorAction SilentlyContinue
    sc.exe delete "apache" | Out-Null

    Remove-Item -Path "C:\Apache24" -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item -Path "C:\nginx" -Recurse -Force -ErrorAction SilentlyContinue

    Import-Module WebAdministration -ErrorAction SilentlyContinue
    # FIX CRÍTICO: Get-Website devuelve TODOS los sitios de IIS, incluidos
    # los de FTP (viven en el mismo árbol IIS:\Sites). El código original
    # borraba indiscriminadamente todo lo que encontrara, lo que eliminó el
    # sitio FTP anónimo de la Tarea 5 (repositorio) la primera vez que se
    # corrió esta limpieza. Ahora solo se tocan sitios que tengan un binding
    # http o https; los sitios FTP quedan intactos.
    Get-Website | Where-Object {
        $protocolos = $_.bindings.Collection | ForEach-Object { $_.protocol }
        ($protocolos -contains 'http') -or ($protocolos -contains 'https')
    } | ForEach-Object {
        Stop-Website -Name $_.Name -ErrorAction SilentlyContinue
        Remove-Website -Name $_.Name -ErrorAction SilentlyContinue
    }
    Write-Host "[OK] Entorno liberado." -ForegroundColor Green
}

# ------------------------------------------------------------------
# 1. FIRMAS SHA256 EN EL REPOSITORIO (utilidad para preparar el FTP)
# ------------------------------------------------------------------
function Administrar-FirmasRepositorio {
    # FIX: el valor por defecto apuntaba a "C:\FTP\LocalUser\repositorio\http\Windows",
    # una ruta que nunca existió en este entorno. La raíz anónima real del
    # repositorio (Tarea 5) es "C:\FTP\LocalUser\Public\general\http\Windows".
    param([string]$RutaRepo = "C:\FTP\LocalUser\Public\general\http\Windows")
    Write-Host "--- GENERANDO FIRMAS SHA256 EN EL REPOSITORIO ---" -ForegroundColor Cyan
    if (-not (Test-Path $RutaRepo)) { Write-Host "[X] Repositorio no encontrado en $RutaRepo" -ForegroundColor Red; return }

    $instaladores = Get-ChildItem -Path $RutaRepo -Recurse -Include "*.zip", "*.msi"
    if ($instaladores.Count -eq 0) { Write-Host "[!] No hay instaladores en el repositorio." -ForegroundColor Yellow; return }

    foreach ($archivo in $instaladores) {
        $rutaHash = "$($archivo.FullName).sha256"
        (Get-FileHash -Path $archivo.FullName -Algorithm SHA256).Hash.ToLower() | Out-File -FilePath $rutaHash -Encoding utf8 -Force
        Write-Host "[OK] Firma creada para $($archivo.Name)" -ForegroundColor Green
    }
}

# ------------------------------------------------------------------
# 2. CLIENTE FTP DINÁMICO (navegación + descarga + verificación de hash)
# ------------------------------------------------------------------
function Navegar-Descargar-FTP {
    Write-Host "--- CONECTANDO AL REPOSITORIO PRIVADO FTP ($($global:FtpServer)) ---" -ForegroundColor Cyan

    # FIX (igual que en Linux): se usan las credenciales globales fijas en
    # vez de pedirlas cada vez; el repositorio FTP de la Tarea 5 no tiene
    # TLS habilitado, así que tampoco se fuerza -k/--ssl en curl.
    $ftpUser = $global:FtpUser
    $ftpPass = $global:FtpPass

    $urlServicios = "ftp://${Global:FtpServer}/general/http/Windows/"
    $rawServicios = curl.exe -s -l -u "${ftpUser}:${ftpPass}" $urlServicios
    # FIX: sin @(), si el filtro deja un solo resultado PowerShell lo
    # "desenvuelve" a un string plano en vez de un array de 1 elemento.
    # Luego $servicios[$i] indexaría CARACTERES del string, no elementos
    # de una lista (mismo bug que rompió $archivos más abajo).
    $servicios = @($rawServicios -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" })

    if ($servicios.Count -eq 0) {
        Write-Host "[X] No se encontraron carpetas de servicio en $urlServicios" -ForegroundColor Red
        return $null
    }

    Write-Host "--- Servicios disponibles en el repositorio (Windows) ---" -ForegroundColor Blue
    for ($i = 0; $i -lt $servicios.Count; $i++) { Write-Host "$($i+1)) $($servicios[$i])" }
    $selServ = Read-Host "Selecciona el número del servicio a instalar"
    $servicio = $servicios[[int]$selServ - 1]

    $urlVersiones = "ftp://${Global:FtpServer}/general/http/Windows/${servicio}/"
    $rawArchivos = curl.exe -s -l -u "${ftpUser}:${ftpPass}" $urlVersiones
    # FIX: mismo problema — si solo hay un .zip/.msi en la carpeta (como
    # pasa aquí con Apache y con Nginx), Where-Object devuelve un string
    # plano y "$archivos[0]" daba solo la primera letra del nombre
    # ("h" de "httpd..."), causando además el error de descarga
    # "curl: (78) The file does not exist" (intentaba bajar un archivo
    # llamado literalmente "h").
    $archivos = @($rawArchivos -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ -match "\.(zip|msi)$" })

    if ($archivos.Count -eq 0) {
        Write-Host "[X] No hay instaladores de $servicio en el FTP." -ForegroundColor Red
        return $null
    }

    Write-Host "--- Versiones disponibles de $servicio ---" -ForegroundColor Blue
    for ($i = 0; $i -lt $archivos.Count; $i++) { Write-Host "$($i+1)) $($archivos[$i])" }
    $selVer = Read-Host "Selecciona el número de versión a descargar"
    $archivoElegido = $archivos[[int]$selVer - 1]

    $dirDescargas = "C:\descargas_ftp"
    if (-not (Test-Path $dirDescargas)) { New-Item -ItemType Directory -Force -Path $dirDescargas | Out-Null }
    $rutaInstalador = "$dirDescargas\$archivoElegido"
    $rutaHash = "$dirDescargas\$archivoElegido.sha256"

    Write-Host "Descargando $archivoElegido y su firma..." -ForegroundColor Cyan
    curl.exe -s --show-error -u "${ftpUser}:${ftpPass}" "${urlVersiones}${archivoElegido}" -o $rutaInstalador
    curl.exe -s --show-error -u "${ftpUser}:${ftpPass}" "${urlVersiones}${archivoElegido}.sha256" -o $rutaHash

    if (-not ((Test-Path $rutaInstalador) -and (Test-Path $rutaHash))) {
        Write-Host "[X] Error: la descarga del instalador o del hash falló." -ForegroundColor Red
        return $null
    }

    $hashCalculado = (Get-FileHash -Path $rutaInstalador -Algorithm SHA256).Hash.ToLower()
    $hashOriginal = ((Get-Content -Path $rutaHash -Raw) -split "\s+")[0].ToLower()

    if ($hashCalculado -eq $hashOriginal) {
        Write-Host "[OK] Integridad confirmada (SHA256 coincide)." -ForegroundColor Green
        return @{ Ruta = $rutaInstalador; Servicio = $servicio }
    } else {
        Write-Host "[X] Error: El archivo descargado está corrupto (hash no coincide)." -ForegroundColor Red
        return $null
    }
}

# ------------------------------------------------------------------
# 3. HTML DE MONITOREO
# ------------------------------------------------------------------
function Generar-HTML-Monitor {
    param([string]$RutaArchivo, [string]$Servidor, [string]$Version, [string]$Puerto, [bool]$IsSSL)
    $protocolo = if ($IsSSL) { "HTTPS (Seguro)" } else { "HTTP (Inseguro)" }
    $bgColor = if ($IsSSL) { "#27ae60" } else { "#c0392b" }

    $htmlContent = @"
<html>
<body style='font-family: Arial; text-align: center; background-color: $bgColor; color: white; padding-top: 50px;'>
    <div style='background: rgba(0,0,0,0.5); display: inline-block; padding: 40px; border-radius: 20px; border: 3px solid white;'>
        <h1 style='margin: 0;'>SERVIDOR WEB: $Servidor</h1>
        <hr style='width: 80%; margin: 20px auto;'>
        <p style='font-size: 1.3em;'><b>Versión:</b> $Version</p>
        <p style='font-size: 1.3em;'><b>Protocolo:</b> $protocolo</p>
        <p style='font-size: 1.3em;'><b>Puerto Escucha:</b> $Puerto</p>
        <p style='font-size: 1.1em; color: #ecf0f1;'>Dominio: $($global:Dominio)</p>
    </div>
</body>
</html>
"@
    Set-Content -Path $RutaArchivo -Value $htmlContent -Force
}

# ------------------------------------------------------------------
# 4. VERIFICACIÓN Y RESUMEN
# ------------------------------------------------------------------
function Verificar-Servicio {
    param([string]$Nombre, [int]$Puerto, [string]$ProcesoONombreServicio, [bool]$EsProceso)

    Write-Host "`n=========================================" -ForegroundColor Blue
    Write-Host "      RESUMEN DE INSTALACIÓN - $Nombre" -ForegroundColor Blue
    Write-Host "=========================================" -ForegroundColor Blue

    $estado = if ($EsProceso) {
        Get-Process -Name $ProcesoONombreServicio -ErrorAction SilentlyContinue
    } else {
        Get-Service -Name $ProcesoONombreServicio -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq "Running" }
    }
    Write-Host -NoNewline "Estado del proceso:      "
    if ($estado) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "FAIL" -ForegroundColor Red }

    Write-Host -NoNewline "Puerto de escucha ($Puerto): "
    $puertoAbierto = Get-NetTCPConnection -LocalPort $Puerto -State Listen -ErrorAction SilentlyContinue
    if ($puertoAbierto) { Write-Host "OK" -ForegroundColor Green } else { Write-Host "CERRADO" -ForegroundColor Red }
    Write-Host "-----------------------------------------" -ForegroundColor Blue
}

# ------------------------------------------------------------------
# 5. IIS WEB (SSL DINÁMICO)
# ------------------------------------------------------------------
function Instalar-IIS-Web-Hibrido {
    Write-Host "`n--- INSTALANDO IIS WEB ---" -ForegroundColor Cyan
    Liberar-Puertos-Web

    $puertoHTTP = Pedir-Puerto "Ingresa el puerto HTTP libre (ej. 8080)"
    $isSSL = (Read-Host "¿Desea activar SSL en este servicio? [S/N]") -match "^[Ss]$"
    if ($isSSL) { $puertoHTTPS = Pedir-Puerto "Ingresa el puerto HTTPS libre (ej. 8443)" }

    Install-WindowsFeature -name Web-Server -IncludeManagementTools | Out-Null

    # FIX: Liberar-Puertos-Web hace Stop-Service sobre W3SVC/WAS al limpiar
    # el entorno (y se llama también desde Apache/Nginx), pero nada los
    # volvía a arrancar. Sin esto, IIS quedaba con el sitio "Started" en
    # metadatos pero el servicio real detenido: proceso FAIL, puerto CERRADO.
    Start-Service WAS -ErrorAction SilentlyContinue
    Start-Service W3SVC -ErrorAction SilentlyContinue

    $siteName = "SitioIIS_Practica7"
    $sitePath = "C:\inetpub\wwwroot\$siteName"
    if (-not (Test-Path $sitePath)) { New-Item -ItemType Directory -Force -Path $sitePath | Out-Null }

    Import-Module WebAdministration
    $VersionIIS = (Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\InetStp").VersionString

    if ($isSSL) {
        $cert = New-SelfSignedCertificate -DnsName "$($global:Dominio)" -CertStoreLocation "cert:\LocalMachine\My"
        New-Website -Name $siteName -Port $puertoHTTP -PhysicalPath $sitePath -Force | Out-Null
        New-WebBinding -Name $siteName -Protocol "https" -Port $puertoHTTPS -IPAddress "*"

        Push-Location IIS:\SslBindings
        Get-Item "cert:\LocalMachine\My\$($cert.Thumbprint)" | New-Item -Path "*!$puertoHTTPS" -Force | Out-Null
        Pop-Location

        $configContent = @"
<?xml version="1.0" encoding="UTF-8"?>
<configuration>
    <system.webServer>
        <rewrite>
            <rules>
                <rule name="HTTP to HTTPS" stopProcessing="true">
                    <match url="(.*)" />
                    <conditions><add input="{HTTPS}" pattern="^OFF$" /></conditions>
                    <action type="Redirect" url="https://$($global:Dominio):$puertoHTTPS/{R:1}" redirectType="Permanent" />
                </rule>
            </rules>
        </rewrite>
    </system.webServer>
</configuration>
"@
        Set-Content -Path "$sitePath\web.config" -Value $configContent -Force
        Generar-HTML-Monitor -RutaArchivo "$sitePath\index.html" -Servidor "IIS" -Version $VersionIIS -Puerto $puertoHTTPS -IsSSL $true

        New-NetFirewallRule -DisplayName "IIS HTTPS $puertoHTTPS" -Direction Inbound -LocalPort $puertoHTTPS -Protocol TCP -Action Allow | Out-Null
        New-NetFirewallRule -DisplayName "IIS HTTP $puertoHTTP" -Direction Inbound -LocalPort $puertoHTTP -Protocol TCP -Action Allow | Out-Null
        Escribir-Resumen "[IIS WEB] Desplegado con SSL en puerto $puertoHTTPS (Redirección desde $puertoHTTP)."
        Start-Website -Name $siteName -ErrorAction SilentlyContinue
        Verificar-Servicio -Nombre "IIS Web" -Puerto $puertoHTTPS -ProcesoONombreServicio "W3SVC" -EsProceso $false
    } else {
        New-Website -Name $siteName -Port $puertoHTTP -PhysicalPath $sitePath -Force | Out-Null
        Generar-HTML-Monitor -RutaArchivo "$sitePath\index.html" -Servidor "IIS" -Version $VersionIIS -Puerto $puertoHTTP -IsSSL $false
        New-NetFirewallRule -DisplayName "IIS HTTP $puertoHTTP" -Direction Inbound -LocalPort $puertoHTTP -Protocol TCP -Action Allow | Out-Null
        Escribir-Resumen "[IIS WEB] Desplegado (Solo HTTP) en puerto $puertoHTTP."
        Start-Website -Name $siteName -ErrorAction SilentlyContinue
        Verificar-Servicio -Nombre "IIS Web" -Puerto $puertoHTTP -ProcesoONombreServicio "W3SVC" -EsProceso $false
    }
}

# ------------------------------------------------------------------
# 6. APACHE (DESCARGA FTP/WEB + SSL DINÁMICO)
# ------------------------------------------------------------------
function Instalar-Apache-Hibrido {
    Write-Host "`n--- INSTALANDO APACHE ---" -ForegroundColor Cyan
    Liberar-Puertos-Web

    Write-Host "1) Descargar de la Web (Vía Chocolatey)"
    Write-Host "2) Descargar del FTP (Repositorio Privado)"
    $origen = Read-Host "Selecciona el origen [1-2]"

    if ($origen -eq "1") {
        Write-Host "Instalando Apache vía Web..." -ForegroundColor Yellow
        Set-ExecutionPolicy Bypass -Scope Process -Force
        if (-not (Get-Command "choco" -ErrorAction SilentlyContinue)) {
            Invoke-Expression ((New-Object System.Net.WebClient).DownloadString('https://community.chocolatey.org/install.ps1')) *>$null
        }
        choco install apache-httpd -y --force --params '"/NoService"' *>$null
        Move-Item -Path "C:\tools\apache24" -Destination "C:\Apache24" -Force -ErrorAction SilentlyContinue
    } else {
        $descarga = Navegar-Descargar-FTP
        if (-not $descarga) { return }
        Write-Host "Extrayendo Apache en C:\..." -ForegroundColor Yellow
        Expand-Archive -Path $descarga.Ruta -DestinationPath "C:\" -Force
    }

    $apacheDir = "C:\Apache24"
    if (-not (Test-Path $apacheDir)) { Write-Host "[X] Error: Apache no se instaló correctamente." -ForegroundColor Red; return }

    $puertoHTTP = Pedir-Puerto "Ingresa el puerto HTTP libre (ej. 8081)"
    $isSSL = (Read-Host "¿Desea activar SSL en este servicio? [S/N]") -match "^[Ss]$"
    if ($isSSL) { $puertoHTTPS = Pedir-Puerto "Ingresa el puerto HTTPS libre (ej. 8444)" }

    $confPath = "$apacheDir\conf\httpd.conf"
    $conf = (Get-Content $confPath | Where-Object { $_ -notmatch '^\s*Listen ' -and $_ -notmatch '^\s*ServerName ' }) -join "`r`n"
    $conf = "Listen $puertoHTTP`r`nServerName localhost:$puertoHTTP`r`n" + $conf
    $conf = $conf -replace 'Define SRVROOT ".*"', 'Define SRVROOT "C:/Apache24"'

    if ($isSSL) {
        $env:OPENSSL_CONF = "$apacheDir\conf\openssl.cnf"
        Push-Location "$apacheDir\bin"
        .\openssl.exe req -x509 -nodes -newkey rsa:2048 -keyout "$apacheDir\conf\server.key" -out "$apacheDir\conf\server.crt" -days 365 -subj "/CN=$($global:Dominio)" 2>$null
        Pop-Location

        $conf = $conf -replace '(?m)^#?\s*LoadModule ssl_module.*$', 'LoadModule ssl_module modules/mod_ssl.so'
        $conf = $conf -replace '(?m)^#?\s*LoadModule rewrite_module.*$', 'LoadModule rewrite_module modules/mod_rewrite.so'
        $conf = $conf -replace '(?m)^#?\s*LoadModule headers_module.*$', 'LoadModule headers_module modules/mod_headers.so'
        # FIX: faltaba habilitar socache_shmcb_module. La directiva
        # SSLSessionCache "shmcb:..." en httpd-ssl.conf requiere este módulo;
        # sin él, "httpd -t" rechaza la config con "'shmcb' session cache
        # not supported" y Apache nunca llega a arrancar con SSL (aunque
        # Start-Process no lo detecta porque no espera ni valida el proceso).
        $conf = $conf -replace '(?m)^#?\s*LoadModule socache_shmcb_module.*$', 'LoadModule socache_shmcb_module modules/mod_socache_shmcb.so'
        $conf += "`r`nInclude conf/extra/httpd-ssl.conf"
        $conf += "`r`n<VirtualHost *:$puertoHTTP>`r`n    ServerName $($global:Dominio)`r`n    RewriteEngine On`r`n    RewriteCond %{HTTPS} off`r`n    RewriteRule ^(.*)$ https://%{SERVER_NAME}:$puertoHTTPS%{REQUEST_URI} [L,R=301]`r`n</VirtualHost>"

        $sslConfContent = @"
Listen $puertoHTTPS
SSLCipherSuite HIGH:MEDIUM:!MD5:!RC4:!3DES
SSLProxyCipherSuite HIGH:MEDIUM:!MD5:!RC4:!3DES
SSLHonorCipherOrder on
SSLProtocol all -SSLv3
SSLProxyProtocol all -SSLv3
SSLPassPhraseDialog  builtin
SSLSessionCache "shmcb:c:/Apache24/logs/ssl_scache(512000)"
SSLSessionCacheTimeout  300

<VirtualHost _default_:$puertoHTTPS>
    DocumentRoot "c:/Apache24/htdocs"
    ServerName $($global:Dominio):$puertoHTTPS
    SSLEngine on
    SSLCertificateFile "c:/Apache24/conf/server.crt"
    SSLCertificateKeyFile "c:/Apache24/conf/server.key"
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</VirtualHost>
"@
        Set-Content -Path "$apacheDir\conf\extra\httpd-ssl.conf" -Value $sslConfContent -Force
        Generar-HTML-Monitor -RutaArchivo "$apacheDir\htdocs\index.html" -Servidor "Apache" -Version "2.4" -Puerto $puertoHTTPS -IsSSL $true
        New-NetFirewallRule -DisplayName "Apache HTTPS $puertoHTTPS" -Direction Inbound -LocalPort $puertoHTTPS -Protocol TCP -Action Allow | Out-Null
        Escribir-Resumen "[APACHE] Desplegado con SSL en puerto $puertoHTTPS (Redirección desde $puertoHTTP)."
    } else {
        $conf = $conf -replace '(?m)^\s*LoadModule ssl_module.*$', '#LoadModule ssl_module modules/mod_ssl.so'
        Generar-HTML-Monitor -RutaArchivo "$apacheDir\htdocs\index.html" -Servidor "Apache" -Version "2.4" -Puerto $puertoHTTP -IsSSL $false
        Escribir-Resumen "[APACHE] Desplegado (Solo HTTP) en puerto $puertoHTTP."
    }

    $conf | Set-Content $confPath
    New-NetFirewallRule -DisplayName "Apache HTTP $puertoHTTP" -Direction Inbound -LocalPort $puertoHTTP -Protocol TCP -Action Allow | Out-Null

    # FIX: antes se lanzaba httpd.exe con Start-Process sin validar nada,
    # así que un error de sintaxis en la config (como el de shmcb) hacía
    # que Apache muriera al instante mientras el script igual imprimía
    # "[OK] Apache iniciado" y el resumen reportaba "Estado del proceso: OK"
    # por una condición de carrera. Ahora se valida la config primero con
    # httpd -t, y si falla se muestra el error real en vez de fingir éxito.
    $testConfig = & "$apacheDir\bin\httpd.exe" -t 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Error de configuración de Apache, no se puede iniciar:" -ForegroundColor Red
        Write-Host $testConfig -ForegroundColor Red
        return
    }

    Start-Process -FilePath "$apacheDir\bin\httpd.exe" -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (-not (Get-Process httpd -ErrorAction SilentlyContinue)) {
        Write-Host "[X] Apache se cerró inmediatamente después de arrancar. Revisa C:\Apache24\logs\error.log" -ForegroundColor Red
        return
    }
    Write-Host "[OK] Apache iniciado en segundo plano." -ForegroundColor Green
    Verificar-Servicio -Nombre "Apache" -Puerto $(if ($isSSL) { $puertoHTTPS } else { $puertoHTTP }) -ProcesoONombreServicio "httpd" -EsProceso $true
}

# ------------------------------------------------------------------
# 7. NGINX (DESCARGA FTP/WEB + SSL DINÁMICO)
# ------------------------------------------------------------------
function Instalar-Nginx-Hibrido {
    Write-Host "`n--- INSTALANDO NGINX ---" -ForegroundColor Cyan
    Liberar-Puertos-Web

    Write-Host "1) Descargar de la Web (Vía Chocolatey)"
    Write-Host "2) Descargar del FTP (Repositorio Privado)"
    $origen = Read-Host "Selecciona el origen [1-2]"

    if ($origen -eq "1") {
        Write-Host "Instalando Nginx vía Web..." -ForegroundColor Yellow
        choco install nginx -y --force *>$null
        $tempDir = (Get-ChildItem -Path "C:\tools", "C:\" -Filter "nginx-*" -Directory -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
        if ($tempDir) { Move-Item -Path $tempDir -Destination "C:\nginx" -Force }
    } else {
        $descarga = Navegar-Descargar-FTP
        if (-not $descarga) { return }
        Write-Host "Extrayendo Nginx en C:\..." -ForegroundColor Yellow
        Expand-Archive -Path $descarga.Ruta -DestinationPath "C:\" -Force
        $tempDir = (Get-ChildItem -Path "C:\" -Filter "nginx-*" -Directory | Select-Object -First 1).FullName
        if ($tempDir) { Move-Item -Path $tempDir -Destination "C:\nginx" -Force }
    }

    $nginxDir = "C:\nginx"
    if (-not (Test-Path $nginxDir)) { Write-Host "[X] Error: Nginx no se instaló." -ForegroundColor Red; return }

    $puertoHTTP = Pedir-Puerto "Ingresa el puerto HTTP libre (ej. 8082)"
    $isSSL = (Read-Host "¿Desea activar SSL en este servicio? [S/N]") -match "^[Ss]$"
    if ($isSSL) { $puertoHTTPS = Pedir-Puerto "Ingresa el puerto HTTPS libre (ej. 8445)" }

    if (-not (Test-Path "$nginxDir\html")) { New-Item -ItemType Directory -Path "$nginxDir\html" -Force | Out-Null }
    if (-not (Test-Path "$nginxDir\conf")) { New-Item -ItemType Directory -Path "$nginxDir\conf" -Force | Out-Null }

    if ($isSSL) {
        $chocoExe = "C:\ProgramData\chocolatey\bin\choco.exe"
        & $chocoExe install openssl -y *>$null
        $env:OPENSSL_CONF = "C:\Program Files\OpenSSL-Win64\bin\openssl.cfg"
        & "C:\Program Files\OpenSSL-Win64\bin\openssl.exe" req -x509 -nodes -newkey rsa:2048 -keyout "$nginxDir\conf\server.key" -out "$nginxDir\conf\server.crt" -days 365 -subj "/CN=$($global:Dominio)" 2>$null

        $nginxConf = @"
worker_processes  1;
events { worker_connections  1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;

    server {
        listen       $puertoHTTP;
        server_name  $($global:Dominio);
        return 301 https://`$host:$puertoHTTPS`$request_uri;
    }

    server {
        listen       $puertoHTTPS ssl;
        server_name  $($global:Dominio);
        ssl_certificate      server.crt;
        ssl_certificate_key  server.key;
        add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
"@
        Set-Content -Path "$nginxDir\conf\nginx.conf" -Value $nginxConf -Force
        Generar-HTML-Monitor -RutaArchivo "$nginxDir\html\index.html" -Servidor "Nginx" -Version "Latest" -Puerto $puertoHTTPS -IsSSL $true
        New-NetFirewallRule -DisplayName "Nginx HTTPS $puertoHTTPS" -Direction Inbound -LocalPort $puertoHTTPS -Protocol TCP -Action Allow | Out-Null
        Escribir-Resumen "[NGINX] Desplegado con SSL en puerto $puertoHTTPS (Redirección desde $puertoHTTP)."
    } else {
        $nginxConf = @"
worker_processes  1;
events { worker_connections  1024; }
http {
    include       mime.types;
    default_type  application/octet-stream;
    sendfile        on;
    keepalive_timeout  65;
    server {
        listen       $puertoHTTP;
        server_name  localhost;
        location / {
            root   html;
            index  index.html index.htm;
        }
    }
}
"@
        Set-Content -Path "$nginxDir\conf\nginx.conf" -Value $nginxConf -Force
        Generar-HTML-Monitor -RutaArchivo "$nginxDir\html\index.html" -Servidor "Nginx" -Version "Latest" -Puerto $puertoHTTP -IsSSL $false
        Escribir-Resumen "[NGINX] Desplegado (Solo HTTP) en puerto $puertoHTTP."
    }

    New-NetFirewallRule -DisplayName "Nginx HTTP $puertoHTTP" -Direction Inbound -LocalPort $puertoHTTP -Protocol TCP -Action Allow | Out-Null

    # FIX (mismo patrón que Apache): Start-Process sin validar nada dejaba
    # que un error de config silenciara un fallo de arranque real mientras
    # el script igual reportaba éxito. Se valida con nginx -t primero y se
    # confirma que el proceso siga vivo después de arrancar.
    $testConfig = & "$nginxDir\nginx.exe" -t -p $nginxDir -c "$nginxDir\conf\nginx.conf" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host "[X] Error de configuración de Nginx, no se puede iniciar:" -ForegroundColor Red
        Write-Host $testConfig -ForegroundColor Red
        return
    }

    Start-Process -FilePath "$nginxDir\nginx.exe" -WorkingDirectory $nginxDir -WindowStyle Hidden
    Start-Sleep -Seconds 2
    if (-not (Get-Process nginx -ErrorAction SilentlyContinue)) {
        Write-Host "[X] Nginx se cerró inmediatamente después de arrancar. Revisa $nginxDir\logs\error.log" -ForegroundColor Red
        return
    }
    Write-Host "[OK] Nginx iniciado en segundo plano." -ForegroundColor Green
    Verificar-Servicio -Nombre "Nginx" -Puerto $(if ($isSSL) { $puertoHTTPS } else { $puertoHTTP }) -ProcesoONombreServicio "nginx" -EsProceso $true
}

# ------------------------------------------------------------------
# 8. IIS FTP (FTPS DINÁMICO)
# ------------------------------------------------------------------
function Instalar-IIS-FTP-Hibrido {
    Write-Host "`n--- INSTALANDO IIS FTP ---" -ForegroundColor Cyan
    Install-WindowsFeature Web-FTP-Server -IncludeManagementTools | Out-Null

    $ftpUser = Read-Host "Ingresa el nombre del usuario FTP a utilizar (Ej. 'repositorio')"
    $ftpPath = "C:\FTP\LocalUser\$ftpUser"
    if (-not (Test-Path $ftpPath)) { Write-Host "[X] La ruta $ftpPath no existe." -ForegroundColor Red; return }

    $puertoFTP = Pedir-Puerto "Ingresa el puerto para el FTP (ej. 21)"
    $isSSL = (Read-Host "¿Desea activar SSL (FTPS) en este servicio? [S/N]") -match "^[Ss]$"

    Import-Module WebAdministration
    if (Get-WebSite -Name "FTP_Practica7" -ErrorAction SilentlyContinue) { Remove-WebSite -Name "FTP_Practica7" }

    New-WebFtpSite -Name "FTP_Practica7" -Port $puertoFTP -PhysicalPath $ftpPath -Force | Out-Null
    Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.userIsolation.mode -Value 0
    Remove-WebConfigurationProperty -Filter "/system.ftpServer/security/authorization" -Name "." -Location "FTP_Practica7" -ErrorAction SilentlyContinue

    if ($isSSL) {
        $cert = New-SelfSignedCertificate -DnsName "$($global:Dominio)" -CertStoreLocation "cert:\LocalMachine\My"
        Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.ssl.serverCertHash -Value $cert.Thumbprint
        Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.ssl.controlChannelPolicy -Value 1
        Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.ssl.dataChannelPolicy -Value 1
        Escribir-Resumen "[IIS FTP] Desplegado con FTPS (Túnel SSL) en puerto $puertoFTP."
    } else {
        Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.ssl.controlChannelPolicy -Value 0
        Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.ssl.dataChannelPolicy -Value 0
        Escribir-Resumen "[IIS FTP] Desplegado (Sin SSL) en puerto $puertoFTP."
    }

    New-NetFirewallRule -DisplayName "IIS FTP $puertoFTP" -Direction Inbound -LocalPort $puertoFTP -Protocol TCP -Action Allow | Out-Null
    Set-ItemProperty "IIS:\Sites\FTP_Practica7" -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true
    Add-WebConfiguration "/system.ftpServer/security/authorization" -Value @{accessType="Allow";users=$ftpUser;permissions="Read,Write"} -PSPath IIS:\ -Location "FTP_Practica7"
    Restart-WebItem "IIS:\Sites\FTP_Practica7"

    Write-Host "[OK] IIS FTP configurado." -ForegroundColor Green
    Verificar-Servicio -Nombre "IIS FTP" -Puerto $puertoFTP -ProcesoONombreServicio "FTPSVC" -EsProceso $false
}
