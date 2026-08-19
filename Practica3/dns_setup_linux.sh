#!/bin/bash
#############################################################################
# Tarea 3 - Automatización del Servidor DNS (BIND9)
# Materia: Sistemas - Prof. Herman Geovany Ayala Zuñiga
# Uso:
#   sudo ./dns_setup_linux.sh [-d dominio] [-i ip_registro] [-w www_ip]
#
# Ejemplos:
#   sudo ./dns_setup_linux.sh
#   sudo ./dns_setup_linux.sh -d reprobados.com -i 192.168.100.30
#
# Diseñado para el entorno de la materia:
#   red_sistemas: 192.168.100.0/24
#   Srv-Linux-Sistemas: 192.168.100.10 (este servidor, BIND9)
#   Srv-Win-Sistemas:   192.168.100.20 (DHCP / DNS Windows)
#   Cliente Mint:        192.168.100.30 (o rango DHCP .50-.150)
#############################################################################

set -euo pipefail

# ------------------------- Colores para salida -----------------------------
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_ok()   { echo -e "${GREEN}[OK]${NC} $1"; }
log_info() { echo -e "${YELLOW}[INFO]${NC} $1"; }
log_err()  { echo -e "${RED}[ERROR]${NC} $1"; }

# ------------------------- Validación de privilegios ------------------------
if [[ $EUID -ne 0 ]]; then
  log_err "Este script debe ejecutarse como root (usa sudo)."
  exit 1
fi

# ------------------------- Valores por defecto ------------------------------
DOMAIN="reprobados.com"
RECORD_IP=""
WWW_IP=""
ZONE_DIR="/var/cache/bind"
NAMED_LOCAL="/etc/bind/named.conf.local"
LOGFILE="/var/log/tarea3_dns_setup.log"

# ------------------------- Parseo de parámetros ------------------------------
while getopts "d:i:w:h" opt; do
  case $opt in
    d) DOMAIN="$OPTARG" ;;
    i) RECORD_IP="$OPTARG" ;;
    w) WWW_IP="$OPTARG" ;;
    h)
      echo "Uso: $0 [-d dominio] [-i ip_para_A] [-w ip_para_www]"
      exit 0
      ;;
    *) echo "Opción inválida"; exit 1 ;;
  esac
done

exec > >(tee -a "$LOGFILE") 2>&1
echo "===== Ejecución: $(date '+%Y-%m-%d %H:%M:%S') ====="

# ------------------------- Función: validar IPv4 -----------------------------
valid_ip() {
  local ip=$1
  local IFS='.'
  read -ra octets <<< "$ip"
  [[ ${#octets[@]} -eq 4 ]] || return 1
  for o in "${octets[@]}"; do
    [[ $o =~ ^[0-9]+$ ]] || return 1
    (( o >= 0 && o <= 255 )) || return 1
  done
  return 0
}

# ------------------------- Función: pedir datos si faltan --------------------
prompt_if_empty() {
  local varname=$1
  local prompt=$2
  local default=$3
  local current
  current="${!varname:-}"
  if [[ -z "$current" ]]; then
    read -rp "$prompt [$default]: " input
    input=${input:-$default}
    while ! valid_ip "$input"; do
      log_err "IP inválida: $input"
      read -rp "$prompt [$default]: " input
      input=${input:-$default}
    done
    eval "$varname=\"$input\""
  fi
}

# ------------------------- Verificación de IP fija del servidor --------------
check_static_ip() {
  log_info "Verificando configuración de IP fija en el servidor..."

  SERVER_IP=""
  local static_iface=""

  # Recorre todas las interfaces ethernet declaradas en netplan y busca
  # alguna que YA esté configurada con dhcp4: false (IP estática), sin
  # asumir que la interfaz de la ruta por defecto es la relevante
  # (en este entorno la ruta por defecto suele ir por la NAT/DHCP, no
  # por la interfaz de red_sistemas).
  local yaml_files
  yaml_files=$(ls /etc/netplan/*.yaml 2>/dev/null || true)

  if [[ -z "$yaml_files" ]]; then
    log_err "No se encontraron archivos netplan en /etc/netplan/."
    exit 1
  fi

  for f in $yaml_files; do
    # Extrae nombres de interfaces (líneas con 4 espacios de indent + ':',
    # que es donde netplan declara cada interfaz dentro de "ethernets:")
    for iface in $(awk '/^    [a-zA-Z0-9]+:/{gsub(/[: ]/,"");print}' "$f"); do
      # Bloque de esa interfaz: desde su línea hasta la siguiente interfaz del mismo nivel
      local block
      block=$(awk -v ifc="$iface" '
        $0 ~ "^    "ifc":"{found=1; next}
        found && /^    [a-zA-Z0-9]+:/{exit}
        found && /^  [a-zA-Z0-9]+:/{exit}
        found{print}
      ' "$f")
      if echo "$block" | grep -q "dhcp4:[[:space:]]*false" && echo "$block" | grep -q "addresses:"; then
        static_iface="$iface"
        SERVER_IP=$(echo "$block" | grep -oP '(?<=addresses:\s\[)\d+(\.\d+){3}')
        break 2
      fi
    done
  done

  if [[ -n "$SERVER_IP" ]]; then
    log_ok "El servidor ya tiene IP fija: $SERVER_IP en $static_iface."
    return
  fi

  # Ninguna interfaz tiene IP estática configurada: pedir datos al usuario
  log_info "No se detectó ninguna interfaz con IP fija configurada."
  local iface
  iface=$(ip route | awk '/default/ {print $5; exit}')
  local netplan_file
  netplan_file=$(grep -l "$iface" /etc/netplan/*.yaml 2>/dev/null | head -n1 || true)

  prompt_if_empty "SERVER_IP" "Ingresa la IP fija para $iface" "192.168.100.10"
  read -rp "Máscara CIDR [24]: " SERVER_CIDR
  SERVER_CIDR=${SERVER_CIDR:-24}
  read -rp "Gateway [192.168.100.1]: " SERVER_GW
  SERVER_GW=${SERVER_GW:-192.168.100.1}

  cp "$netplan_file" "${netplan_file}.bak.$(date +%s)"
  cat > "$netplan_file" <<EOF
network:
  version: 2
  ethernets:
    $iface:
      dhcp4: no
      addresses: [$SERVER_IP/$SERVER_CIDR]
      routes:
        - to: default
          via: $SERVER_GW
      nameservers:
        addresses: [127.0.0.1, 8.8.8.8]
EOF
  netplan apply
  log_ok "IP fija $SERVER_IP/$SERVER_CIDR aplicada en $iface."
}

# ------------------------- Instalación idempotente de BIND9 ------------------
install_bind9() {
  if dpkg -l | grep -qw bind9; then
    log_ok "BIND9 ya está instalado. Se omite instalación."
  else
    log_info "Instalando bind9, bind9utils y bind9-doc..."
    apt-get update -y
    apt-get install -y bind9 bind9utils bind9-doc
    log_ok "BIND9 instalado correctamente."
  fi

  if systemctl is-active --quiet named || systemctl is-active --quiet bind9; then
    log_ok "El servicio BIND9 ya está activo."
  else
    log_info "Habilitando e iniciando el servicio BIND9..."
    systemctl enable --now named 2>/dev/null || systemctl enable --now bind9
  fi
}

# ------------------------- Configuración de zona ------------------------------
configure_zone() {
  local zone_file="$ZONE_DIR/db.$DOMAIN"
  local serial
  serial=$(date +%Y%m%d%H)

  # Idempotencia: si la zona ya está declarada en named.conf.local, no duplicar
  if grep -q "zone \"$DOMAIN\"" "$NAMED_LOCAL" 2>/dev/null; then
    log_info "La zona $DOMAIN ya existe en $NAMED_LOCAL. Se actualizará el archivo de zona."
  else
    log_info "Agregando declaración de zona para $DOMAIN..."
    cat >> "$NAMED_LOCAL" <<EOF

zone "$DOMAIN" {
    type master;
    file "$zone_file";
};
EOF
    log_ok "Zona declarada en $NAMED_LOCAL."
  fi

  log_info "Generando archivo de zona $zone_file..."
  cat > "$zone_file" <<EOF
;
; Archivo de zona para $DOMAIN
; Generado automáticamente - Tarea 3
;
\$TTL    604800
@       IN      SOA     ns.$DOMAIN. admin.$DOMAIN. (
                          $serial   ; Serial (AAAAMMDDHH)
                          604800    ; Refresh
                           86400    ; Retry
                         2419200    ; Expire
                          604800 )  ; Negative Cache TTL
;
@       IN      NS      ns.$DOMAIN.
@       IN      A       $RECORD_IP
ns      IN      A       $SERVER_IP
www     IN      A       $WWW_IP
EOF

  chown root:bind "$zone_file"
  chmod 644 "$zone_file"
  log_ok "Archivo de zona generado con serial $serial."
}

# ------------------------- Validación de sintaxis ------------------------------
validate_and_reload() {
  log_info "Validando sintaxis de configuración (named-checkconf)..."
  if named-checkconf; then
    log_ok "Sintaxis de named.conf válida."
  else
    log_err "Error de sintaxis en named.conf. Revisa el log."
    exit 1
  fi

  log_info "Validando archivo de zona (named-checkzone)..."
  if named-checkzone "$DOMAIN" "$ZONE_DIR/db.$DOMAIN"; then
    log_ok "Archivo de zona válido."
  else
    log_err "Error en el archivo de zona."
    exit 1
  fi

  log_info "Recargando BIND9..."
  systemctl reload named 2>/dev/null || systemctl reload bind9
  log_ok "Servicio recargado con éxito."
}

# ------------------------- Prueba de resolución local ---------------------------
test_resolution() {
  log_info "Probando resolución local con dig/nslookup..."
  sleep 1
  echo "----- dig $DOMAIN @127.0.0.1 -----"
  dig @127.0.0.1 "$DOMAIN" +short || true
  echo "----- dig www.$DOMAIN @127.0.0.1 -----"
  dig @127.0.0.1 "www.$DOMAIN" +short || true

  local result
  result=$(dig @127.0.0.1 "$DOMAIN" +short | head -n1)
  if [[ "$result" == "$RECORD_IP" ]]; then
    log_ok "Resolución de $DOMAIN correcta -> $result"
  else
    log_err "La resolución no coincide. Esperado: $RECORD_IP, Obtenido: $result"
  fi
}

# ============================== MAIN ==============================
echo "======================================================"
echo " Tarea 3 - Automatización de Servidor DNS (BIND9)"
echo "======================================================"

check_static_ip
prompt_if_empty "RECORD_IP" "IP a la que apuntará $DOMAIN (registro A)" "192.168.100.30"
prompt_if_empty "WWW_IP" "IP a la que apuntará www.$DOMAIN" "$RECORD_IP"

install_bind9
configure_zone
validate_and_reload
test_resolution

echo "======================================================"
log_ok "Configuración de DNS finalizada. Log guardado en $LOGFILE"
echo "======================================================"