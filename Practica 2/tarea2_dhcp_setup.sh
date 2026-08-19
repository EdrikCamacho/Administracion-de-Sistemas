#!/bin/bash
###############################################################################
# Tarea 2 - Automatización y Gestión del Servidor DHCP (Linux)
# Universidad Autónoma de Sinaloa - FIM
# Servicio: isc-dhcp-server
# Uso: sudo ./dhcp_setup.sh
###############################################################################

set -o pipefail

CONF_FILE="/etc/dhcp/dhcpd.conf"
DEFAULT_FILE="/etc/default/isc-dhcp-server"
LEASES_FILE="/var/lib/dhcp/dhcpd.leases"
SERVICE_NAME="isc-dhcp-server"
LOG_FILE="/var/log/dhcp_setup.log"

# ----------------------------------------------------------------------------
# Utilidades
# ----------------------------------------------------------------------------
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

require_root() {
    if [[ $EUID -ne 0 ]]; then
        echo "Este script debe ejecutarse como root (usa sudo)." >&2
        exit 1
    fi
}

# Validación de formato IPv4 (0-255 por octeto)
validate_ip() {
    local ip="$1"
    local IFS='.'
    local -a octets=($ip)
    if [[ ! $ip =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
        return 1
    fi
    for octet in "${octets[@]}"; do
        if (( octet < 0 || octet > 255 )); then
            return 1
        fi
    done
    return 0
}

read_valid_ip() {
    local prompt="$1"
    local ip
    while true; do
        read -rp "$prompt: " ip
        if validate_ip "$ip"; then
            echo "$ip"
            return 0
        else
            echo "  -> Formato de IPv4 inválido. Intenta de nuevo (ej. 192.168.100.1)." >&2
        fi
    done
}

read_valid_int() {
    local prompt="$1"
    local val
    while true; do
        read -rp "$prompt: " val
        if [[ $val =~ ^[0-9]+$ ]]; then
            echo "$val"
            return 0
        else
            echo "  -> Debe ser un número entero." >&2
        fi
    done
}

detect_interface() {
    # Detecta la primera interfaz activa distinta de loopback
    ip -o link show up | awk -F': ' '{print $2}' | grep -v '^lo$' | head -n1
}

# ----------------------------------------------------------------------------
# 1. Lógica de instalación idempotente
# ----------------------------------------------------------------------------
install_dhcp_server() {
    if dpkg -l | grep -qw isc-dhcp-server && systemctl list-unit-files | grep -qw "${SERVICE_NAME}.service"; then
        log "isc-dhcp-server ya está instalado. Se omite la instalación."
        return 0
    fi

    log "isc-dhcp-server no encontrado. Iniciando instalación desatendida..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y >> "$LOG_FILE" 2>&1
    apt-get install -y isc-dhcp-server >> "$LOG_FILE" 2>&1

    if [[ $? -ne 0 ]]; then
        log "ERROR: Falló la instalación de isc-dhcp-server."
        exit 1
    fi
    log "Instalación completada correctamente."
}

# ----------------------------------------------------------------------------
# 2. Orquestación de configuración dinámica
# ----------------------------------------------------------------------------
configure_dhcp() {
    echo ""
    echo "=== Configuración interactiva del ámbito DHCP ==="
    read -rp "Nombre descriptivo del ámbito (Scope): " SCOPE_NAME

    local NETWORK RANGE_START RANGE_END GATEWAY DNS LEASE_TIME MAX_LEASE INTERFACE

    NETWORK=$(read_valid_ip "Dirección de red (ej. 192.168.100.0)")
    RANGE_START=$(read_valid_ip "Rango inicial de asignación")
    RANGE_END=$(read_valid_ip "Rango final de asignación")
    GATEWAY=$(read_valid_ip "Puerta de enlace (Router/Gateway)")
    DNS=$(read_valid_ip "Servidor DNS")
    LEASE_TIME=$(read_valid_int "Tiempo de concesión (Lease Time) en segundos, ej. 86400")
    MAX_LEASE=$((LEASE_TIME * 2))

    INTERFACE=$(detect_interface)
    read -rp "Interfaz de red a usar [detectada: ${INTERFACE}]: " IFACE_INPUT
    INTERFACE=${IFACE_INPUT:-$INTERFACE}

    # Respaldo del archivo de configuración existente
    if [[ -f "$CONF_FILE" ]]; then
        cp "$CONF_FILE" "${CONF_FILE}.bak.$(date +%s)"
        log "Respaldo de configuración previa creado."
    fi

    cat > "$CONF_FILE" <<EOF
# Configuración generada automáticamente - $(date)
# Ámbito: ${SCOPE_NAME}
default-lease-time ${LEASE_TIME};
max-lease-time ${MAX_LEASE};
authoritative;

subnet ${NETWORK} netmask 255.255.255.0 {
    range ${RANGE_START} ${RANGE_END};
    option routers ${GATEWAY};
    option domain-name-servers ${DNS};
    option subnet-mask 255.255.255.0;
    option broadcast-address ${NETWORK%.*}.255;
}
EOF

    log "Archivo ${CONF_FILE} generado."

    # Configurar la interfaz de escucha
    if [[ -f "$DEFAULT_FILE" ]]; then
        sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"${INTERFACE}\"/" "$DEFAULT_FILE"
        if ! grep -q "^INTERFACESv4=" "$DEFAULT_FILE"; then
            echo "INTERFACESv4=\"${INTERFACE}\"" >> "$DEFAULT_FILE"
        fi
    fi

    # Validación de sintaxis antes de reiniciar
    echo ""
    echo "Validando sintaxis del archivo de configuración..."
    dhcpd -t -cf "$CONF_FILE"
    if [[ $? -ne 0 ]]; then
        log "ERROR: La configuración generada no es válida. Revisa ${CONF_FILE}."
        exit 1
    fi
    log "Sintaxis válida."

    systemctl restart "$SERVICE_NAME"
    systemctl enable "$SERVICE_NAME" >> "$LOG_FILE" 2>&1

    if systemctl is-active --quiet "$SERVICE_NAME"; then
        log "Servicio ${SERVICE_NAME} activo y corriendo."
    else
        log "ERROR: El servicio no pudo iniciar. Revisa: journalctl -u ${SERVICE_NAME}"
        exit 1
    fi
}

# ----------------------------------------------------------------------------
# 3. Módulo de monitoreo y validación de estado
# ----------------------------------------------------------------------------
show_status() {
    echo ""
    echo "=== Estado del servicio ${SERVICE_NAME} ==="
    systemctl status "$SERVICE_NAME" --no-pager -l
}

show_leases() {
    echo ""
    echo "=== Concesiones (leases) activas ==="
    if [[ -f "$LEASES_FILE" ]]; then
        awk '
            /^lease/ {ip=$2}
            /binding state active/ {active=1}
            /client-hostname/ {host=$2}
            /^}/ && active {print "IP:", ip, " Host:", host; active=0; host="(desconocido)"}
        ' "$LEASES_FILE"
    else
        echo "No se encontró el archivo de leases en ${LEASES_FILE}."
    fi
}

validate_config() {
    echo ""
    echo "=== Validación de sintaxis (dhcpd -t) ==="
    dhcpd -t -cf "$CONF_FILE"
}

monitor_menu() {
    while true; do
        echo ""
        echo "=== Módulo de Monitoreo DHCP ==="
        echo "1) Ver estado del servicio"
        echo "2) Listar concesiones (leases) activas"
        echo "3) Validar sintaxis de configuración"
        echo "4) Ver log en vivo (Ctrl+C para salir)"
        echo "5) Volver al menú principal"
        read -rp "Selecciona una opción: " opt
        case $opt in
            1) show_status ;;
            2) show_leases ;;
            3) validate_config ;;
            4) journalctl -u "$SERVICE_NAME" -f ;;
            5) break ;;
            *) echo "Opción inválida." ;;
        esac
    done
}

# ----------------------------------------------------------------------------
# Menú principal
# ----------------------------------------------------------------------------
main_menu() {
    while true; do
        echo ""
        echo "===== Gestión Automatizada de Servidor DHCP (Linux) ====="
        echo "1) Instalar/verificar isc-dhcp-server (idempotente)"
        echo "2) Configurar ámbito DHCP (interactivo)"
        echo "3) Módulo de monitoreo"
        echo "4) Salir"
        read -rp "Selecciona una opción: " opt
        case $opt in
            1) install_dhcp_server ;;
            2) configure_dhcp ;;
            3) monitor_menu ;;
            4) exit 0 ;;
            *) echo "Opción inválida." ;;
        esac
    done
}

require_root
touch "$LOG_FILE"
main_menu