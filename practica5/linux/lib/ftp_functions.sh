#!/bin/bash
###############################################################################
# ftp_functions.sh
# Biblioteca de funciones para la Practica 5 - Automatizacion de Servidor FTP
# Materia: Sistemas Operativos / Infraestructura - Prof. Herman Geovany Ayala Zuñiga
#
# Esta biblioteca se carga con "source" desde ftp_setup.sh y sigue la misma
# arquitectura modular usada en la Practica 4 (SSH): funciones encapsuladas,
# separadas del script principal de menu.
###############################################################################

# ------------------------- Rutas y constantes -------------------------------
FTP_BASE="/srv/ftp"
FTP_GENERAL="${FTP_BASE}/general"
FTP_GRUPOS="${FTP_BASE}/grupos"
FTP_USUARIOS="${FTP_BASE}/usuarios"
FTP_HOMES="${FTP_BASE}/home"
VSFTPD_CONF="/etc/vsftpd.conf"
VSFTPD_USERLIST="/etc/vsftpd/user_list"
GRUPOS_VALIDOS=("reprobados" "recursadores")
GRUPO_FTP_COMUN="ftpusers"

# ------------------------- Utilidades generales ------------------------------

verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "[ERROR] Este script debe ejecutarse como root (usa sudo)." >&2
        exit 1
    fi
}

instalar_paquete() {
    local paquete="$1"
    if dpkg -l | grep -qw "$paquete"; then
        echo "[OK] El paquete '$paquete' ya esta instalado."
    else
        echo "[INFO] Instalando '$paquete'..."
        apt-get update -qq
        apt-get install -y "$paquete"
    fi
}

grupo_es_valido() {
    local grupo="$1"
    for g in "${GRUPOS_VALIDOS[@]}"; do
        [[ "$g" == "$grupo" ]] && return 0
    done
    return 1
}

usuario_existe() {
    id "$1" &>/dev/null
}

# ------------------------- Instalacion e idempotencia ------------------------

instalar_vsftpd() {
    verificar_root
    instalar_paquete "vsftpd"
    mkdir -p /etc/vsftpd/user_conf
    systemctl enable vsftpd &>/dev/null
    echo "[OK] vsftpd instalado y habilitado."
}

configurar_vsftpd() {
    verificar_root

    if [[ -f "$VSFTPD_CONF" && ! -f "${VSFTPD_CONF}.bak" ]]; then
        cp "$VSFTPD_CONF" "${VSFTPD_CONF}.bak"
        echo "[INFO] Respaldo creado en ${VSFTPD_CONF}.bak"
    fi

    cat > "$VSFTPD_CONF" <<EOF
# Generado automaticamente por ftp_setup.sh - Practica 5
listen=YES
listen_ipv6=NO

# --- Acceso anonimo: solo lectura a /general ---
anonymous_enable=YES
anon_root=${FTP_GENERAL}
anon_upload_enable=NO
anon_mkdir_write_enable=NO
anon_other_write_enable=NO
no_anon_password=YES

# --- Usuarios locales autenticados ---
local_enable=YES
write_enable=YES
local_umask=002
chroot_local_user=YES
allow_writeable_chroot=NO

# --- Control de acceso: solo usuarios FTP autorizados ---
userlist_enable=YES
userlist_deny=NO
userlist_file=${VSFTPD_USERLIST}

# --- Seguridad y sesiones pasivas ---
pam_service_name=vsftpd
tcp_wrappers=YES
pasv_enable=YES
pasv_min_port=40000
pasv_max_port=40100
xferlog_enable=YES
EOF

    mkdir -p /etc/vsftpd
    touch "$VSFTPD_USERLIST"

    # nologin debe considerarse shell valido para que PAM permita el login FTP
    if ! grep -q "/usr/sbin/nologin" /etc/shells; then
        echo "/usr/sbin/nologin" >> /etc/shells
    fi

    systemctl restart vsftpd
    echo "[OK] vsftpd configurado y reiniciado."
}

# ------------------------- Grupos y estructura base ---------------------------

crear_grupos_y_estructura_base() {
    verificar_root

    for grupo in "${GRUPOS_VALIDOS[@]}" "$GRUPO_FTP_COMUN"; do
        if ! getent group "$grupo" &>/dev/null; then
            groupadd "$grupo"
            echo "[OK] Grupo '$grupo' creado."
        else
            echo "[OK] Grupo '$grupo' ya existe."
        fi
    done

    mkdir -p "$FTP_GENERAL" "$FTP_GRUPOS" "$FTP_USUARIOS" "$FTP_HOMES"

    # /general: propiedad root:ftpusers, escribible por cualquier usuario FTP
    chown root:"$GRUPO_FTP_COMUN" "$FTP_GENERAL"
    chmod 2775 "$FTP_GENERAL"

    # Carpetas de grupo: solo escribibles por su grupo respectivo
    for grupo in "${GRUPOS_VALIDOS[@]}"; do
        mkdir -p "${FTP_GRUPOS}/${grupo}"
        chown root:"$grupo" "${FTP_GRUPOS}/${grupo}"
        chmod 2770 "${FTP_GRUPOS}/${grupo}"
    done

    echo "[OK] Estructura base creada en ${FTP_BASE} (general, grupos/reprobados, grupos/recursadores)."
}

# ------------------------- Gestion de usuarios --------------------------------

# Monta (bind) las 3 carpetas visibles dentro del home FTP del usuario:
# general, <grupo>, <usuario>. Se registran en /etc/fstab para persistir
# entre reinicios.
montar_vistas_usuario() {
    local usuario="$1" grupo="$2"
    local home="${FTP_HOMES}/${usuario}"

    mkdir -p "${home}/general" "${home}/${grupo}" "${home}/${usuario}"

    declare -A binds=(
        ["${FTP_GENERAL}"]="${home}/general"
        ["${FTP_GRUPOS}/${grupo}"]="${home}/${grupo}"
        ["${FTP_USUARIOS}/${usuario}"]="${home}/${usuario}"
    )

    for origen in "${!binds[@]}"; do
        destino="${binds[$origen]}"
        if ! mountpoint -q "$destino"; then
            mount --bind "$origen" "$destino"
        fi
        if ! grep -qF "$origen $destino none bind" /etc/fstab; then
            echo "${origen} ${destino} none bind 0 0" >> /etc/fstab
        fi
    done
}

desmontar_vista_grupo() {
    local usuario="$1" grupo_actual="$2"
    local destino="${FTP_HOMES}/${usuario}/${grupo_actual}"

    if mountpoint -q "$destino"; then
        umount "$destino"
    fi
    rmdir "$destino" 2>/dev/null
    # Elimina la linea correspondiente de /etc/fstab
    sed -i "\|${FTP_GRUPOS}/${grupo_actual} ${destino} none bind|d" /etc/fstab
}

crear_usuario_ftp() {
    local usuario="$1" password="$2" grupo="$3"

    if ! grupo_es_valido "$grupo"; then
        echo "[ERROR] Grupo invalido: '$grupo'. Debe ser reprobados o recursadores." >&2
        return 1
    fi

    if usuario_existe "$usuario"; then
        echo "[ERROR] El usuario '$usuario' ya existe, se omite." >&2
        return 1
    fi

    local home="${FTP_HOMES}/${usuario}"

    # Usuario del sistema sin shell interactivo, home = raiz FTP del usuario
    useradd -m -d "$home" -s /usr/sbin/nologin -g "$grupo" "$usuario"
    echo "${usuario}:${password}" | chpasswd
    usermod -aG "$GRUPO_FTP_COMUN" "$usuario"

    # El "root" del chroot debe ser de root y NO escribible (requisito de vsftpd)
    chown root:root "$home"
    chmod 755 "$home"

    # Carpeta personal real (fuera del chroot, se monta despues por bind)
    mkdir -p "${FTP_USUARIOS}/${usuario}"
    chown "${usuario}:${grupo}" "${FTP_USUARIOS}/${usuario}"
    chmod 700 "${FTP_USUARIOS}/${usuario}"

    montar_vistas_usuario "$usuario" "$grupo"

    # Autoriza al usuario para iniciar sesion por FTP
    if ! grep -qx "$usuario" "$VSFTPD_USERLIST"; then
        echo "$usuario" >> "$VSFTPD_USERLIST"
    fi

    echo "[OK] Usuario FTP '${usuario}' creado en grupo '${grupo}'."
}

alta_masiva_usuarios() {
    verificar_root
    local n
    read -rp "Cuantos usuarios deseas crear? " n

    if ! [[ "$n" =~ ^[0-9]+$ ]] || [[ "$n" -le 0 ]]; then
        echo "[ERROR] Numero invalido." >&2
        return 1
    fi

    for (( i=1; i<=n; i++ )); do
        echo "--- Usuario $i de $n ---"
        read -rp "Nombre de usuario: " usuario
        read -rsp "Contraseña: " password; echo
        read -rp "Grupo (reprobados/recursadores): " grupo
        crear_usuario_ftp "$usuario" "$password" "$grupo"
    done

    systemctl restart vsftpd
}

cambiar_grupo_usuario() {
    verificar_root
    local usuario grupo_nuevo grupo_actual
    read -rp "Usuario a modificar: " usuario
    read -rp "Nuevo grupo (reprobados/recursadores): " grupo_nuevo

    if ! usuario_existe "$usuario"; then
        echo "[ERROR] El usuario '$usuario' no existe." >&2
        return 1
    fi
    if ! grupo_es_valido "$grupo_nuevo"; then
        echo "[ERROR] Grupo invalido." >&2
        return 1
    fi

    grupo_actual=$(id -gn "$usuario")
    if [[ "$grupo_actual" == "$grupo_nuevo" ]]; then
        echo "[INFO] El usuario ya pertenece a ese grupo."
        return 0
    fi

    desmontar_vista_grupo "$usuario" "$grupo_actual"
    usermod -g "$grupo_nuevo" "$usuario"
    montar_vistas_usuario "$usuario" "$grupo_nuevo"

    echo "[OK] '${usuario}' movido de '${grupo_actual}' a '${grupo_nuevo}'."
}