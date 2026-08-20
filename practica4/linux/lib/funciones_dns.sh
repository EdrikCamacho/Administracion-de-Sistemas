#!/bin/bash
###############################################################################
# funciones_dns.sh
# Lógica de la Tarea 3 (servidor DNS con BIND9) migrada a funciones.
# Requiere: funciones_comunes.sh
###############################################################################

ZONA_LOCAL="/etc/bind/named.conf.local"
DIR_ZONAS="/var/cache/bind"

# --- instalar_dns -----------------------------------------------------------
function instalar_dns() {
    verificar_root
    instalar_paquete "bind9"
    instalar_paquete "bind9utils"
    instalar_paquete "bind9-doc"
}

# --- crear_zona_dns ------------------------------------------------------------
# Uso: crear_zona_dns <dominio>  (ej: reprobados.com)
function crear_zona_dns() {
    local dominio="$1"
    cat >> "$ZONA_LOCAL" <<EOF

zone "$dominio" {
    type master;
    file "$DIR_ZONAS/db.$dominio";
};
EOF
    echo "[OK] Zona '$dominio' agregada a $ZONA_LOCAL"
}

# --- agregar_registro_a ---------------------------------------------------------
# Uso: agregar_registro_a <dominio> <host> <ip>
# host puede ser "@" (raíz) o "www"
function agregar_registro_a() {
    local dominio="$1" host="$2" ip="$3"
    local archivo_zona="$DIR_ZONAS/db.$dominio"

    validar_ip "$ip" || { echo "[ERROR] IP inválida: $ip" >&2; return 1; }

    if [[ ! -f "$archivo_zona" ]]; then
        cp /etc/bind/db.local "$archivo_zona"
    fi

    echo "$host    IN    A    $ip" >> "$archivo_zona"
    echo "[OK] Registro A agregado: $host.$dominio -> $ip"
}

# --- iniciar_dns -----------------------------------------------------------
function iniciar_dns() {
    named-checkconf
    habilitar_servicio "bind9"
}