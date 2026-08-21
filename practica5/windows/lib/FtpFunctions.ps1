###############################################################################
# FtpFunctions.ps1  (v2 -- version consolidada con todas las correcciones)
# Biblioteca de funciones - Practica 5: Automatizacion de Servidor FTP (Windows/IIS)
#
# Se carga por punto (. .\FtpFunctions.ps1) desde ftp_setup.ps1.
#
# Historial de fixes incorporados (por si hay que depurar mas adelante):
#  - Permisos NTFS SIEMPRE por SID real (nunca por nombre de texto como
#    "Authenticated Users" o "Everyone") -- en este servidor esos nombres no
#    se resuelven via icacls/.NET por el idioma del sistema.
#  - Estructura fisica LocalUser\Public\general (requisito del modo de
#    aislamiento IsolateAllDirectories para que el anonimo tenga home).
#  - Reglas de autorizacion FTP escritas con -PSPath "IIS:\" -Location
#    $SitioFTP (patron documentado por Microsoft), no con -PSPath
#    "IIS:\Sites\$SitioFTP".
#  - La seccion system.ftpServer/security/authorization se desbloquea con
#    appcmd antes de escribir en ella (viene bloqueada por defecto).
#  - Reglas: "?" = anonimo (no "*", no "IUSR" literal); roles con los grupos
#    para autenticados (no "?", que significaria "solo anonimo").
#  - SSL en modo "Allow" (no "Require") en ambos canales, porque no hay
#    certificado en este entorno de practica.
#  - LocalAccountTokenFilterPolicy habilitado (cuentas locales conservan sus
#    grupos en logon de red/FTP).
#  - Web-Ftp-Ext instalado junto con Web-Ftp-Server.
###############################################################################

# ------------------------- Rutas y constantes -------------------------------
$Script:FtpBase       = "C:\FTP"
$Script:FtpLocalUser  = "$FtpBase\LocalUser"
$Script:FtpPublic     = "$FtpLocalUser\Public"
$Script:FtpGeneral    = "$FtpPublic\general"      # contenido real, visible para todos
$Script:FtpGrupos     = "$FtpBase\grupos"
$Script:FtpUsuarios   = "$FtpBase\usuarios"       # carpetas personales reales, centralizadas
$Script:SitioFTP      = "FTPServer"
$Script:GruposValidos = @("reprobados", "recursadores")

# SIDs universales (independientes del idioma del sistema)
$Script:SidAdministradores = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-544")
$Script:SidUsuarios        = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-32-545") # incluye Authenticated Users
$Script:SidIUSR            = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-17")

# ------------------------- Utilidades generales ------------------------------

function Verificar-Admin {
    $esAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    if (-not $esAdmin) {
        Write-Error "Este script debe ejecutarse como Administrador."
        exit 1
    }
}

function Grupo-EsValido {
    param([string]$Grupo)
    return $GruposValidos -contains $Grupo
}

# Otorga permisos NTFS usando un SecurityIdentifier real (nunca un nombre de
# texto), para no depender de la resolucion de nombres del sistema.
function Otorgar-PermisoSid {
    param(
        [string]$Path,
        [System.Security.Principal.SecurityIdentifier]$Sid,
        [string]$Rights = "ReadAndExecute",
        [switch]$Reiniciar
    )
    $acl = Get-Acl $Path
    if ($Reiniciar) {
        # Rompe la herencia sin copiar las reglas heredadas previas
        $acl.SetAccessRuleProtection($true, $false)
        # Administradores y SYSTEM SIEMPRE conservan acceso total, para que
        # el propio script (corriendo como Administrador) no pierda acceso
        # a la carpeta que acaba de proteger.
        $sidSystem = New-Object System.Security.Principal.SecurityIdentifier("S-1-5-18")
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $SidAdministradores, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
        $acl.AddAccessRule((New-Object System.Security.AccessControl.FileSystemAccessRule(
            $sidSystem, "FullControl", "ContainerInherit,ObjectInherit", "None", "Allow")))
    }
    $regla = New-Object System.Security.AccessControl.FileSystemAccessRule(
        $Sid, $Rights, "ContainerInherit,ObjectInherit", "None", "Allow"
    )
    $acl.AddAccessRule($regla)
    Set-Acl $Path $acl
}

# ------------------------- Instalacion e idempotencia ------------------------

function Instalar-IISFTP {
    Verificar-Admin
    $features = @("Web-Server", "Web-Ftp-Server", "Web-Ftp-Ext", "Web-WebServer", "Web-Mgmt-Console")
    foreach ($f in $features) {
        $estado = Get-WindowsFeature -Name $f
        if ($estado.InstallState -ne "Installed") {
            Write-Host "[INFO] Instalando característica $f..."
            Install-WindowsFeature -Name $f | Out-Null
        } else {
            Write-Host "[OK] $f ya estaba instalado."
        }
    }
    Import-Module WebAdministration -ErrorAction SilentlyContinue

    # Windows filtra por defecto el token de las cuentas LOCALES (no de
    # dominio, no Administrador) cuando inician sesion "por red" -- que es
    # como IIS FTP trata el login con autenticacion Basic, incluso en
    # localhost. Ese filtrado les quita las membresias de grupo (reprobados/
    # recursadores) del token usado para el chequeo de NTFS, provocando
    # "home directory inaccessible" aunque los permisos esten perfectos.
    # Se desactiva ese filtrado para cuentas locales.
    $regPath = "HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System"
    $valorActual = Get-ItemProperty -Path $regPath -Name "LocalAccountTokenFilterPolicy" -ErrorAction SilentlyContinue
    if (-not $valorActual -or $valorActual.LocalAccountTokenFilterPolicy -ne 1) {
        New-ItemProperty -Path $regPath -Name "LocalAccountTokenFilterPolicy" -PropertyType DWord -Value 1 -Force | Out-Null
        Write-Host "[OK] LocalAccountTokenFilterPolicy habilitado."
        Write-Host "[AVISO] Este cambio requiere REINICIAR la VM para aplicarse por completo." -ForegroundColor Yellow
    } else {
        Write-Host "[OK] LocalAccountTokenFilterPolicy ya estaba habilitado."
    }
}

function Configurar-EstructuraBase {
    Verificar-Admin

    New-Item -ItemType Directory -Force -Path $FtpGeneral, $FtpGrupos, $FtpUsuarios | Out-Null

    # /general: lectura para el anonimo (IUSR), lectura/escritura para
    # cualquier usuario autenticado (grupo incorporado "Usuarios", que en
    # Windows incluye por defecto a Authenticated Users como miembro anidado).
    Otorgar-PermisoSid -Path $FtpGeneral -Sid $SidAdministradores -Rights "FullControl" -Reiniciar
    Otorgar-PermisoSid -Path $FtpGeneral -Sid $SidUsuarios -Rights "Modify"
    Otorgar-PermisoSid -Path $FtpGeneral -Sid $SidIUSR -Rights "ReadAndExecute"

    foreach ($grupo in $GruposValidos) {
        if (-not (Get-LocalGroup -Name $grupo -ErrorAction SilentlyContinue)) {
            New-LocalGroup -Name $grupo -Description "Grupo FTP: $grupo"
            Write-Host "[OK] Grupo local '$grupo' creado."
        } else {
            Write-Host "[OK] Grupo local '$grupo' ya existe."
        }

        $rutaGrupo = "$FtpGrupos\$grupo"
        New-Item -ItemType Directory -Force -Path $rutaGrupo | Out-Null

        # SID real del grupo (recien creado o existente) -- nunca su nombre de texto
        $sidGrupo = (Get-LocalGroup -Name $grupo).SID
        Otorgar-PermisoSid -Path $rutaGrupo -Sid $SidAdministradores -Rights "FullControl" -Reiniciar
        Otorgar-PermisoSid -Path $rutaGrupo -Sid $sidGrupo -Rights "Modify"
    }

    Write-Host "[OK] Estructura base creada en $FtpBase."
}

function Configurar-SitioFTP {
    Verificar-Admin
    Import-Module WebAdministration

    if (-not (Get-Website -Name $SitioFTP -ErrorAction SilentlyContinue)) {
        New-WebFtpSite -Name $SitioFTP -Port 21 -PhysicalPath $FtpBase -Force | Out-Null
        Write-Host "[OK] Sitio FTP '$SitioFTP' creado en el puerto 21."
    } else {
        Write-Host "[OK] Sitio FTP '$SitioFTP' ya existe."
    }

    $path = "IIS:\Sites\$SitioFTP"

    # Autenticacion: anonima (para /general) + basica (para usuarios locales)
    Set-ItemProperty $path -Name ftpServer.security.authentication.anonymousAuthentication.enabled -Value $true
    Set-ItemProperty $path -Name ftpServer.security.authentication.basicAuthentication.enabled -Value $true

    # Aislamiento fisico de usuario: cada usuario (y el anonimo, via "Public")
    # tiene su propia carpeta bajo LocalUser\
    Set-ItemProperty $path -Name ftpServer.userIsolation.mode -Value "IsolateAllDirectories"

    # Por defecto IIS exige SSL en el canal de control aunque no haya
    # certificado configurado. Para este entorno de practica (sin SSL) se
    # permite (no se exige) SSL tanto en el canal de control como en el de datos.
    Set-ItemProperty $path -Name ftpServer.security.ssl.controlChannelPolicy -Value "SslAllow"
    Set-ItemProperty $path -Name ftpServer.security.ssl.dataChannelPolicy -Value "SslAllow"

    # La seccion de autorizacion FTP viene bloqueada por defecto a nivel de
    # applicationHost.config (overrideModeDefault="Deny"). Hay que desbloquearla
    # una vez para poder escribir reglas por sitio.
    $appcmd = "$env:windir\System32\inetsrv\appcmd.exe"
    & $appcmd unlock config -section:system.ftpServer/security/authorization | Out-Null

    # Reglas de autorizacion FTP: "?" es el simbolo documentado por IIS para
    # "usuario anonimo". "roles" con los grupos = solo autenticados.
    #
    # IMPORTANTE: se escribe con -PSPath "IIS:\" -Location $SitioFTP (patron
    # documentado por Microsoft para system.ftpServer/security/authorization)
    # en vez de -PSPath "IIS:\Sites\$SitioFTP".
    Clear-WebConfiguration -PSPath "IIS:\" -Filter "/system.ftpServer/security/authorization" -Location $SitioFTP -ErrorAction SilentlyContinue
    Add-WebConfiguration "/system.ftpServer/security/authorization" -PSPath "IIS:\" -Location $SitioFTP -Value @{
        accessType = "Allow"; roles = ""; users = "?"; permissions = "Read"
    } | Out-Null
    Add-WebConfiguration "/system.ftpServer/security/authorization" -PSPath "IIS:\" -Location $SitioFTP -Value @{
        accessType = "Allow"; roles = ($GruposValidos -join ","); users = ""; permissions = "Read,Write"
    } | Out-Null

    Restart-WebItem $path -Verbose:$false

    # Estructura fisica requerida por "IsolateAllDirectories":
    # LocalUser\Public para el anonimo, LocalUser\<usuario> para cada usuario.
    New-Item -ItemType Directory -Force -Path $FtpPublic | Out-Null

    # IIS necesita poder atravesar C:\FTP y C:\FTP\LocalUser para resolver el
    # home de cada usuario/anonimo. Se otorga solo transito (sin heredar hacia
    # subcarpetas), ya que general/grupos/usuarios ya tienen su propia ACL.
    Otorgar-PermisoSid -Path $FtpBase -Sid $SidIUSR -Rights "ReadAndExecute"
    Otorgar-PermisoSid -Path $FtpBase -Sid $SidUsuarios -Rights "ReadAndExecute"
    Otorgar-PermisoSid -Path $FtpLocalUser -Sid $SidIUSR -Rights "ReadAndExecute"
    Otorgar-PermisoSid -Path $FtpLocalUser -Sid $SidUsuarios -Rights "ReadAndExecute"

    Write-Host "[OK] Sitio FTP configurado (anonimo solo lectura, autenticados lectura/escritura)."
}

# ------------------------- Gestion de usuarios --------------------------------

function Crear-VistasUsuario {
    param([string]$Usuario, [string]$Grupo)

    $homeDir = "$FtpLocalUser\$Usuario"
    New-Item -ItemType Directory -Force -Path $homeDir | Out-Null

    # El propio usuario necesita entrar a su carpeta home
    $sidUsuario = (Get-LocalUser -Name $Usuario).SID
    Otorgar-PermisoSid -Path $homeDir -Sid $sidUsuario -Rights "Modify" -Reiniciar

    $carpetaPersonal = "$FtpUsuarios\$Usuario"
    New-Item -ItemType Directory -Force -Path $carpetaPersonal | Out-Null
    Otorgar-PermisoSid -Path $carpetaPersonal -Sid $sidUsuario -Rights "Modify" -Reiniciar

    # "Vistas" via virtual directories anidadas de IIS dentro del home
    # aislado del usuario, apuntando a las carpetas fisicas reales.
    $sitePath = "IIS:\Sites\$SitioFTP"
    $userNode = "$sitePath\LocalUser\$Usuario"

    if (-not (Test-Path $userNode)) {
        New-Item $userNode -Type VirtualDirectory -PhysicalPath $homeDir -Force | Out-Null
    }

    $vistas = @{
        "general" = $FtpGeneral
        "$Grupo"  = "$FtpGrupos\$Grupo"
        "$Usuario" = $carpetaPersonal
    }
    foreach ($nombre in $vistas.Keys) {
        $childPath = "$userNode\$nombre"
        if (-not (Test-Path $childPath)) {
            New-Item $childPath -Type VirtualDirectory -PhysicalPath $vistas[$nombre] -Force | Out-Null
        }
    }
}

function Eliminar-VistaGrupo {
    param([string]$Usuario, [string]$GrupoActual)
    $enlace = "IIS:\Sites\$SitioFTP\LocalUser\$Usuario\$GrupoActual"
    if (Test-Path $enlace) {
        Remove-Item $enlace -Recurse -Force
    }
}

function Validar-Contrasena {
    param([string]$Contra)
    if ($Contra.Length -lt 8) {
        Write-Host "[-] La contraseña debe tener al menos 8 caracteres." -ForegroundColor Red
        return $false
    }
    $categorias = 0
    if ($Contra -match "[A-Z]") { $categorias++ }
    if ($Contra -match "[a-z]") { $categorias++ }
    if ($Contra -match "\d")    { $categorias++ }
    if ($Contra -match "[^a-zA-Z0-9]") { $categorias++ }
    if ($categorias -lt 3) {
        Write-Host "[-] Debe incluir al menos 3 de: mayúsculas, minúsculas, números, símbolos." -ForegroundColor Red
        return $false
    }
    return $true
}

function Crear-UsuarioFTP {
    param(
        [string]$Usuario,
        [securestring]$Password,
        [string]$PasswordPlano,
        [string]$Grupo
    )

    if (-not (Grupo-EsValido $Grupo)) {
        Write-Error "Grupo invalido: '$Grupo'. Debe ser reprobados o recursadores."
        return
    }
    if (Get-LocalUser -Name $Usuario -ErrorAction SilentlyContinue) {
        Write-Error "El usuario '$Usuario' ya existe, se omite."
        return
    }
    if ($PasswordPlano -and -not (Validar-Contrasena $PasswordPlano)) {
        Write-Error "Contraseña rechazada para '$Usuario'."
        return
    }

    try {
        New-LocalUser -Name $Usuario -Password $Password -PasswordNeverExpires -AccountNeverExpires -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "No se pudo crear el usuario '$Usuario': $($_.Exception.Message)"
        return
    }

    try {
        Add-LocalGroupMember -Group $Grupo -Member $Usuario -ErrorAction Stop
    } catch {
        Write-Error "Se creó el usuario pero no se pudo agregar al grupo '$Grupo': $($_.Exception.Message)"
        return
    }

    Crear-VistasUsuario -Usuario $Usuario -Grupo $Grupo

    Write-Host "[OK] Usuario FTP '$Usuario' creado en el grupo '$Grupo'."
}

function Alta-MasivaUsuarios {
    Verificar-Admin
    $n = Read-Host "Cuantos usuarios deseas crear?"
    if (-not ($n -as [int]) -or [int]$n -le 0) {
        Write-Error "Numero invalido."
        return
    }

    for ($i = 1; $i -le [int]$n; $i++) {
        Write-Host "--- Usuario $i de $n ---"
        $usuario = Read-Host "Nombre de usuario"

        $passwordPlano = $null
        do {
            $passwordPlano = Read-Host "Contraseña (min. 8 caracteres, 3 de 4: mayús/minús/número/símbolo)"
        } while (-not (Validar-Contrasena $passwordPlano))
        $passwordSecure = ConvertTo-SecureString $passwordPlano -AsPlainText -Force

        $grupo = Read-Host "Grupo (reprobados/recursadores)"
        Crear-UsuarioFTP -Usuario $usuario -Password $passwordSecure -PasswordPlano $passwordPlano -Grupo $grupo
    }
}

function Cambiar-GrupoUsuario {
    Verificar-Admin
    $usuario = Read-Host "Usuario a modificar"
    $grupoNuevo = Read-Host "Nuevo grupo (reprobados/recursadores)"

    if (-not (Get-LocalUser -Name $usuario -ErrorAction SilentlyContinue)) {
        Write-Error "El usuario '$usuario' no existe."
        return
    }
    if (-not (Grupo-EsValido $grupoNuevo)) {
        Write-Error "Grupo invalido."
        return
    }

    $grupoActual = ($GruposValidos | Where-Object { (Get-LocalGroupMember -Group $_ | Where-Object Name -match "\\$usuario$") }) | Select-Object -First 1

    if ($grupoActual -eq $grupoNuevo) {
        Write-Host "[INFO] El usuario ya pertenece a ese grupo."
        return
    }
    if ($grupoActual) {
        Remove-LocalGroupMember -Group $grupoActual -Member $usuario
        Eliminar-VistaGrupo -Usuario $usuario -GrupoActual $grupoActual
    }

    Add-LocalGroupMember -Group $grupoNuevo -Member $usuario
    $nuevaVista = "IIS:\Sites\$SitioFTP\LocalUser\$usuario\$grupoNuevo"
    if (-not (Test-Path $nuevaVista)) {
        New-Item $nuevaVista -Type VirtualDirectory -PhysicalPath "$FtpGrupos\$grupoNuevo" -Force | Out-Null
    }

    Write-Host "[OK] '$usuario' movido de '$grupoActual' a '$grupoNuevo'."
}
