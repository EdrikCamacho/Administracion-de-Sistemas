#!/bin/bash
###############################################################################
# ftp_setup.sh
# Script principal - Practica 5: Automatizacion de Servidor FTP (Linux/vsftpd)
#
# Uso: sudo ./ftp_setup.sh
###############################################################################

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "${SCRIPT_DIR}/lib/ftp_functions.sh"

mostrar_menu() {
    echo ""
    echo "==================================================="
    echo "  Practica 5 - Automatizacion de Servidor FTP (vsftpd)"
    echo "==================================================="
    echo "1) Instalar vsftpd"
    echo "2) Configurar vsftpd (anonimo + local, escritura)"
    echo "3) Crear grupos y estructura base (general, grupos)"
    echo "4) Alta masiva de usuarios (n usuarios)"
    echo "5) Cambiar de grupo a un usuario existente"
    echo "6) Mostrar estado del servicio"
    echo "0) Salir"
    echo "==================================================="
}

mostrar_estado() {
    systemctl status vsftpd --no-pager || true
    echo ""
    echo "Usuarios FTP autorizados (${VSFTPD_USERLIST}):"
    cat "$VSFTPD_USERLIST" 2>/dev/null || echo "(vacio)"
}

verificar_root

while true; do
    mostrar_menu
    read -rp "Selecciona una opcion: " opcion
    case "$opcion" in
        1) instalar_vsftpd ;;
        2) configurar_vsftpd ;;
        3) crear_grupos_y_estructura_base ;;
        4) alta_masiva_usuarios ;;
        5) cambiar_grupo_usuario ;;
        6) mostrar_estado ;;
        0) echo "Saliendo..."; exit 0 ;;
        *) echo "[ERROR] Opcion invalida." >&2 ;;
    esac
done