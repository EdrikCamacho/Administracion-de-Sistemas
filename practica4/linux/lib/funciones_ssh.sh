#!/bin/bash
###############################################################################
# funciones_ssh.sh
# Funciones para instalar y asegurar OpenSSH-Server en el nodo Linux.
# Requiere: funciones_comunes.sh (instalar_paquete, habilitar_servicio)
###############################################################################

# --- instalar_ssh ---------------------------------------------------------
function instalar_ssh() {
    verificar_root
    instalar_paquete "openssh-server"
    habilitar_servicio "ssh"
}

# --- configurar_firewall_ssh -------------------------------------------------
# Abre el puerto 22/tcp en ufw (si está presente) para permitir el acceso
# remoto una vez que se cierre la consola física/virtual.
function configurar_firewall_ssh() {
    verificar_root
    if command -v ufw >/dev/null 2>&1; then
        ufw allow 22/tcp
        ufw --force enable
        echo "[OK] Puerto 22/tcp permitido en ufw."
    else
        echo "[AVISO] ufw no está instalado; instálalo con 'apt install ufw' o gestiona iptables manualmente."
    fi
}

# --- mostrar_ip_ssh ------------------------------------------------------------
# Muestra la IP del servidor para poder conectarse por SSH desde el cliente.
function mostrar_ip_ssh() {
    echo "[INFO] Direcciones IP disponibles para conexión SSH:"
    ip -4 addr show | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | grep -v '127.0.0.1'
}

# --- endurecer_ssh ---------------------------------------------------------
# Hardening básico: deshabilita login root directo por SSH (recomendado
# ejecutarlo YA CONECTADO por SSH con un usuario con sudo, nunca antes).
function endurecer_ssh() {
    verificar_root
    local config="/etc/ssh/sshd_config"
    cp "$config" "${config}.bak.$(date +%Y%m%d%H%M%S)"
    sed -i 's/^#\?PermitRootLogin.*/PermitRootLogin no/' "$config"
    sed -i 's/^#\?PasswordAuthentication.*/PasswordAuthentication yes/' "$config"
    habilitar_servicio "ssh"
    echo "[OK] sshd_config endurecido (PermitRootLogin no). Respaldo creado."
}