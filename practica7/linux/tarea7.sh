#!/bin/bash
# ============================================================================
# TAREA 7 - ORQUESTADOR HÍBRIDO E INFRAESTRUCTURA DE DESPLIEGUE SEGURO (LINUX)
# Este script es SOLO el menú: toda la lógica vive en tarea7_functions.sh
# ============================================================================

if [ "$EUID" -ne 0 ]; then
    echo "Este script debe ejecutarse como root (sudo ./tarea7.sh)"
    exit 1
fi

DIR_ACTUAL="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$DIR_ACTUAL/tarea7_functions.sh"

# --- COLORES ---
export VERDE='\033[0;32m'
export ROJO='\033[0;31m'
export AMARILLO='\033[1;33m'
export CYAN='\033[0;36m'
export AZUL='\033[0;34m'
export RESET='\033[0m'

# --- VARIABLES GLOBALES (ajustar a tu entorno) ---
export DOMINIO="www.reprobados.com"
export FTP_SERVER="192.168.100.10"     # IP del servidor FTP privado (Tarea 5)
export FTP_USER="Edrik"
export FTP_PASS="Reprobado123."
export DIR_DESCARGAS="/root/descargas_ftp"
export SSL_DIR="/etc/ssl/reprobados"
export PUERTO_SSL_ACTIVO="Ninguno"
RESUMEN_GLOBAL=()

instalar_servicio_menu() {
    local servicio=$1

    echo -e "\n${CYAN}=== Despliegue de $servicio ===${RESET}"
    echo "1) Repositorio Web oficial (apt-get)"
    echo "2) Repositorio Privado (FTP - Tarea 5)"
    read -rp "Selecciona el origen [1-2]: " origen

    local metodo="" paquete=""
    if [ "$origen" == "1" ]; then
        metodo="web"
    elif [ "$origen" == "2" ]; then
        if ! navegar_y_descargar_ftp; then
            echo -e "${ROJO}[X] No se pudo completar la descarga desde el FTP. Se cancela.${RESET}"
            return
        fi
        if [ "$SERVICIO_ELEGIDO_FTP" != "$servicio" ]; then
            echo -e "${AMARILLO}[!] Elegiste la carpeta '$SERVICIO_ELEGIDO_FTP' en el FTP; se instalará ese servicio.${RESET}"
            servicio="$SERVICIO_ELEGIDO_FTP"
        fi
        metodo="ftp"
        paquete="$PAQUETE_DESCARGADO"
    else
        echo -e "${ROJO}[ERROR] Opción inválida.${RESET}"
        return
    fi

    pedir_puerto "Ingresa el puerto principal de escucha para $servicio (ej. 8080, 21): "
    local puerto=$PUERTO_LEIDO

    instalar_y_configurar_servicio "$servicio" "$metodo" "$puerto" "$paquete"
    aplicar_ssl_servicio "$servicio" "$puerto"
    realizar_resumen_instalacion "$servicio" "$puerto"
}

menu_principal() {
    verificar_dependencias
    while true; do
        echo -e "\n${AZUL}==========================================${RESET}"
        echo -e "${AZUL}  TAREA 7 - DESPLIEGUE SEGURO (LINUX)${RESET}"
        echo -e "${AZUL}==========================================${RESET}"
        echo "1) Instalar / Asegurar vsftpd (FTP)"
        echo "2) Instalar / Asegurar Apache (HTTP)"
        echo "3) Instalar / Asegurar Nginx (HTTP)"
        echo "4) Instalar / Asegurar Tomcat (HTTP)"
        echo "5) Ver resumen general de la sesión"
        echo "6) Salir"
        read -rp "Selecciona una opción [1-6]: " opcion

        case $opcion in
            1) instalar_servicio_menu "vsftpd" ;;
            2) instalar_servicio_menu "Apache" ;;
            3) instalar_servicio_menu "Nginx" ;;
            4) instalar_servicio_menu "Tomcat" ;;
            5) mostrar_resumen_global ;;
            6) echo "Saliendo..."; exit 0 ;;
            *) echo -e "${ROJO}Opción inválida.${RESET}" ;;
        esac
    done
}

menu_principal
