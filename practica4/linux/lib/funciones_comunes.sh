#!/bin/bash
###############################################################################
# funciones_comunes.sh
# Biblioteca de funciones genéricas reutilizadas por todos los módulos
# (DHCP, DNS, SSH). Se carga con "source" desde main.sh.
###############################################################################

# --- verificar_root ---------------------------------------------------------
# Aborta la ejecución si el script no corre como root.
function verificar_root() {
    if [[ "$EUID" -ne 0 ]]; then
        echo "[ERROR] Este script debe ejecutarse como root (usa sudo)." >&2
        exit 1
    fi
}

# --- instalar_paquete --------------------------------------------------------
# Instala un paquete apt solo si no está instalado ya.
# Uso: instalar_paquete "bind9"
function instalar_paquete() {S
    local paquete="$1"
    if dpkg -l | grep -qw "$paquete"; then
        echo "[OK] '$paquete' ya está instalado."
    else
        echo "[INFO] Instalando '$paquete'..."
        apt update -qq && apt install -y "$paquete"
    fi
}

# --- validar_ip ---------------------------------------------------------------
# Valida formato de una IPv4. Devuelve 0 si es válida, 1 si no.
# Uso: validar_ip "192.168.100.10" || echo "IP inválida"
function validar_ip() {
    local ip="$1"
    local IFS='.'
    read -ra octetos <<< "$ip"

    [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1

    for octeto in "${octetos[@]}"; do
        if (( octeto < 0 || octeto > 255 )); then
            return 1
        fi
    done
    return 0
}

# --- habilitar_servicio -------------------------------------------------------
# Habilita e inicia un servicio systemd, verificando su estado final.
# Uso: habilitar_servicio "ssh"
function habilitar_servicio() {
    local servicio="$1"
    echo "[INFO] Habilitando '$servicio' en el arranque (systemctl enable)..."
    systemctl enable "$servicio"
    echo "[INFO] Iniciando '$servicio'..."
    systemctl restart "$servicio"

    if systemctl is-active --quiet "$servicio"; then
        echo "[OK] '$servicio' está activo y habilitado en el boot."
    else
        echo "[ERROR] '$servicio' no pudo iniciar. Revisa: systemctl status $servicio" >&2
        return 1
    fi
}

# --- pausar -------------------------------------------------------------------
# Pausa la ejecución del menú hasta que el usuario presione Enter.
function pausar() {
    read -rp $'\nPresiona ENTER para continuar...' _
}