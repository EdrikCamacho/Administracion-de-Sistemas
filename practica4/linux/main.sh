#!/bin/bash
###############################################################################
# main.sh — Punto de entrada único del servidor Linux.
# Carga las bibliotecas de funciones y expone un menú de administración.
###############################################################################

DIR_ACTUAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$DIR_ACTUAL/lib/funciones_comunes.sh"
source "$DIR_ACTUAL/lib/funciones_dhcp.sh"
source "$DIR_ACTUAL/lib/funciones_dns.sh"
source "$DIR_ACTUAL/lib/funciones_ssh.sh"

function mostrar_menu() {
    clear
    cat <<'EOF'
==========================================================
   Administración de Servicios de Red - Servidor Linux
==========================================================
 1) Instalar y habilitar SSH
 2) Configurar firewall para SSH (puerto 22)
 3) Mostrar IP para conexión SSH
 4) Endurecer configuración SSH (deshabilitar root)
 --------------------------------------------------------
 5) Instalar servidor DHCP
 6) Configurar ámbito DHCP (192.168.100.0/24)
 7) Iniciar servicio DHCP
 --------------------------------------------------------
 8) Instalar servidor DNS (BIND9)
 9) Crear zona reprobados.com
10) Iniciar servicio DNS
 --------------------------------------------------------
 0) Salir
==========================================================
EOF
}

function main() {
    verificar_root
    local opcion
    while true; do
        mostrar_menu
        read -rp "Selecciona una opción: " opcion
        case "$opcion" in
            1) instalar_ssh ;;
            2) configurar_firewall_ssh ;;
            3) mostrar_ip_ssh ;;
            4) endurecer_ssh ;;
            5) instalar_dhcp ;;
            6) configurar_ambito_dhcp "192.168.100.0" "255.255.255.0" \
                   "192.168.100.50" "192.168.100.150" "192.168.100.1" "192.168.100.10" ;;
            7) iniciar_dhcp ;;
            8) instalar_dns ;;
            9) crear_zona_dns "reprobados.com"
               agregar_registro_a "reprobados.com" "@" "192.168.100.30"
               agregar_registro_a "reprobados.com" "www" "192.168.100.30" ;;
            10) iniciar_dns ;;
            0) echo "Saliendo..."; exit 0 ;;
            *) echo "[ERROR] Opción inválida." ;;
        esac
        pausar
    done
}

main