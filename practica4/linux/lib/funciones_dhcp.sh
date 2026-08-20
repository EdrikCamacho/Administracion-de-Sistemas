#!/bin/bash
###############################################################################
# funciones_dhcp.sh
# Lógica de la Tarea 2 (servidor DHCP) migrada a funciones reutilizables.
# Requiere: funciones_comunes.sh
###############################################################################

DHCP_CONFIG="/etc/dhcp/dhcpd.conf"
DHCP_INTERFACES="/etc/default/isc-dhcp-server"

# --- instalar_dhcp -----------------------------------------------------------
function instalar_dhcp() {
    verificar_root
    instalar_paquete "isc-dhcp-server"
}

# --- configurar_ambito_dhcp ---------------------------------------------------
# Uso: configurar_ambito_dhcp <red> <mascara> <rango_inicio> <rango_fin> <gateway> <dns>
function configurar_ambito_dhcp() {
    local red="$1" mascara="$2" inicio="$3" fin="$4" gateway="$5" dns="$6"

    for ip in "$red" "$inicio" "$fin" "$gateway" "$dns"; do
        validar_ip "$ip" || { echo "[ERROR] IP inválida: $ip" >&2; return 1; }
    done

    cp "$DHCP_CONFIG" "${DHCP_CONFIG}.bak.$(date +%Y%m%d%H%M%S)" 2>/dev/null

    cat >> "$DHCP_CONFIG" <<EOF

subnet $red netmask $mascara {
    range $inicio $fin;
    option routers $gateway;
    option domain-name-servers $dns;
}
EOF
    echo "[OK] Ámbito DHCP $red configurado (rango $inicio - $fin)."
}

# --- definir_interfaz_dhcp -----------------------------------------------------
# Uso: definir_interfaz_dhcp "ens33"
function definir_interfaz_dhcp() {
    local interfaz="$1"
    sed -i "s/^INTERFACESv4=.*/INTERFACESv4=\"$interfaz\"/" "$DHCP_INTERFACES"
    echo "[OK] Interfaz DHCP establecida en: $interfaz"
}

# --- iniciar_dhcp -----------------------------------------------------------
function iniciar_dhcp() {
    habilitar_servicio "isc-dhcp-server"
}