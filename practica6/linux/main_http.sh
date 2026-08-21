#!/bin/bash
###############################################################################
# main_http.sh - Práctica 6
# Menú principal de despliegue dinámico de servicios HTTP (Ubuntu Server)
# Uso: sudo ./main_http.sh   (ejecutar vía SSH, nunca en consola física/virtual)
###############################################################################

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/http_functions.sh"

mostrar_menu() {
    echo ""
    echo "======================================"
    echo " Práctica 6 - Despliegue HTTP Dinámico"
    echo "======================================"
    echo "1) Instalar / configurar Apache2"
    echo "2) Instalar / configurar Nginx"
    echo "3) Instalar / configurar Tomcat"
    echo "4) Salir"
    echo "--------------------------------------"
}

flujo_apache() {
    listar_versiones_apt "apache2" || return
    pedir_puerto_valido "$(obtener_puerto_actual_apache)"
    instalar_apache "$VERSION_SELECCIONADA" "$PUERTO_SELECCIONADO"
    configurar_firewall "$PUERTO_SELECCIONADO"
    probar_headers_http "$PUERTO_SELECCIONADO"
}

flujo_nginx() {
    listar_versiones_apt "nginx" || return
    pedir_puerto_valido "$(obtener_puerto_actual_nginx)"
    instalar_nginx "$VERSION_SELECCIONADA" "$PUERTO_SELECCIONADO"
    configurar_firewall "$PUERTO_SELECCIONADO"
    probar_headers_http "$PUERTO_SELECCIONADO"
}

flujo_tomcat() {
    local major
    while true; do
        read -rp "¿Tomcat 9 (LTS/Estable) o 10 (Desarrollo/Latest)? [9/10]: " major
        [[ "$major" == "9" || "$major" == "10" ]] && break
        log_err "Opción inválida."
    done

    listar_versiones_tomcat "$major" || return
    pedir_puerto_valido "$(obtener_puerto_actual_tomcat)"
    instalar_tomcat "$major" "$VERSION_SELECCIONADA" "$PUERTO_SELECCIONADO"
    configurar_firewall "$PUERTO_SELECCIONADO"
    probar_headers_http "$PUERTO_SELECCIONADO"
}

main() {
    verificar_root
    while true; do
        mostrar_menu
        read -rp "Seleccione una opción: " opcion
        case "$opcion" in
            1) flujo_apache ;;
            2) flujo_nginx ;;
            3) flujo_tomcat ;;
            4) log_info "Saliendo..."; exit 0 ;;
            *) log_err "Opción inválida." ;;
        esac
    done
}

main
