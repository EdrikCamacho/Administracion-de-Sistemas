#!/bin/bash
#############################################################################
# Tarea 3 - Script de Validación desde el Cliente
# Ejecutar en el cliente (Linux Mint) apuntando su DNS al servidor bajo prueba.
#
# Uso:
#   ./dns_test_client.sh [-d dominio] [-e ip_esperada] [-s ip_servidor_dns]
#
# Genera un log con evidencia (nslookup + ping) para el checklist de la
# sección 5 del documento (Protocolo de Pruebas y Validación).
#############################################################################

set -uo pipefail

DOMAIN="reprobados.com"
EXPECTED_IP=""
DNS_SERVER=""
LOGFILE="evidencia_tarea3_$(date +%Y%m%d_%H%M%S).log"

while getopts "d:e:s:h" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    e) EXPECTED_IP="$OPTARG" ;;
    s) DNS_SERVER="$OPTARG" ;;
    h) echo "Uso: $0 [-d dominio] [-e ip_esperada] [-s ip_servidor_dns]"; exit 0 ;;
    *) exit 1 ;;
  esac
done

[[ -z "$EXPECTED_IP" ]] && read -rp "IP esperada para $DOMAIN: " EXPECTED_IP
[[ -z "$DNS_SERVER" ]] && read -rp "IP del servidor DNS a probar: " DNS_SERVER

exec > >(tee "$LOGFILE") 2>&1

echo "======================================================"
echo " Evidencia de Pruebas - Tarea 3 (Cliente)"
echo " Fecha: $(date '+%Y-%m-%d %H:%M:%S')"
echo " Dominio: $DOMAIN | Servidor DNS: $DNS_SERVER | IP esperada: $EXPECTED_IP"
echo "======================================================"

echo -e "\n--- Prueba 1: nslookup $DOMAIN ---"
nslookup "$DOMAIN" "$DNS_SERVER"

echo -e "\n--- Prueba 2: nslookup www.$DOMAIN ---"
nslookup "www.$DOMAIN" "$DNS_SERVER"

echo -e "\n--- Prueba 3: ping www.$DOMAIN ---"
ping -c 4 "www.$DOMAIN"

RESOLVED_IP=$(nslookup "$DOMAIN" "$DNS_SERVER" 2>/dev/null | awk '/^Address/{a=$2} END{print a}')

echo -e "\n======================================================"
echo " RESUMEN"
echo "======================================================"
if [[ "$RESOLVED_IP" == "$EXPECTED_IP" ]]; then
  echo "[OK] $DOMAIN resolvio a $RESOLVED_IP (coincide con lo esperado)"
else
  echo "[FAIL] $DOMAIN resolvio a '$RESOLVED_IP', se esperaba '$EXPECTED_IP'"
fi
echo "======================================================"
echo "Log completo guardado en: $LOGFILE"
echo "Adjunta capturas de pantalla de este log en la sección 5 del documento."