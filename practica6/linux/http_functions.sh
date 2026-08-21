#!/bin/bash
###############################################################################
# http_functions.sh
# Librería de funciones - Práctica 6: Despliegue Dinámico de Servicios HTTP
# Multi-Versión (Apache2, Nginx, Tomcat) sobre Ubuntu Server 24.04
#
# Este archivo NO se ejecuta solo. Debe cargarse con "source" desde
# main_http.sh
###############################################################################

# ---------- Salida en consola ----------
readonly C_OK="\e[32m"
readonly C_ERR="\e[31m"
readonly C_WARN="\e[33m"
readonly C_INFO="\e[36m"
readonly C_RESET="\e[0m"

log_ok()   { echo -e "${C_OK}[OK]${C_RESET} $1"; }
log_err()  { echo -e "${C_ERR}[ERROR]${C_RESET} $1"; }
log_warn() { echo -e "${C_WARN}[AVISO]${C_RESET} $1"; }
log_info() { echo -e "${C_INFO}[INFO]${C_RESET} $1"; }

# Puertos reservados por SSH/DNS/DHCP/FTP/RDP/etc. (prácticas anteriores)
readonly PUERTOS_RESERVADOS=(20 21 22 23 25 53 67 68 111 123 135 139 445 3389)

###############################################################################
# verificar_root
###############################################################################
verificar_root() {
    if [[ $EUID -ne 0 ]]; then
        log_err "Este script debe ejecutarse como root (usa sudo)."
        exit 1
    fi
}

###############################################################################
# validar_entrada_alfanumerica <cadena>
# Rechaza vacío y caracteres especiales peligrosos (inyección de comandos).
# Solo permite letras, números, punto, guion y guion bajo.
###############################################################################
validar_entrada_alfanumerica() {
    local valor="$1"
    [[ -z "$valor" ]] && return 1
    [[ "$valor" =~ ^[a-zA-Z0-9._-]+$ ]] && return 0
    return 1
}

###############################################################################
# validar_puerto <puerto>
###############################################################################
validar_puerto() {
    local puerto="$1"

    if ! [[ "$puerto" =~ ^[0-9]+$ ]]; then
        log_err "El puerto debe ser un valor numérico."
        return 1
    fi

    if (( puerto < 1 || puerto > 65535 )); then
        log_err "El puerto debe estar entre 1 y 65535."
        return 1
    fi

    local reservado
    for reservado in "${PUERTOS_RESERVADOS[@]}"; do
        if (( puerto == reservado )); then
            log_err "El puerto $puerto está reservado (SSH/DNS/DHCP/FTP/RDP)."
            return 1
        fi
    done

    return 0
}

###############################################################################
# puerto_ocupado <puerto>  -> 0 = ocupado, 1 = libre
###############################################################################
puerto_ocupado() {
    local puerto="$1"
    if ss -ltn "( sport = :$puerto )" 2>/dev/null | grep -q ":$puerto"; then
        return 0
    fi
    return 1
}

###############################################################################
# pedir_puerto_valido [puerto_actual]  -> deja el resultado en PUERTO_SELECCIONADO
# Si el servicio que se va a (re)configurar YA está escuchando en
# [puerto_actual], se permite reingresar ese mismo puerto sin marcarlo como
# "ocupado" (evita falso positivo al reconfigurar un servicio ya instalado).
###############################################################################
pedir_puerto_valido() {
    local puerto_actual="${1:-0}"
    local puerto
    while true; do
        read -rp "Ingrese el puerto de escucha deseado: " puerto
        validar_puerto "$puerto" || continue

        if [[ "$puerto_actual" != "0" && "$puerto" == "$puerto_actual" ]]; then
            log_info "El puerto $puerto ya pertenece a este mismo servicio; se reconfigurará sin conflicto."
            PUERTO_SELECCIONADO="$puerto"
            break
        fi

        if puerto_ocupado "$puerto"; then
            log_err "El puerto $puerto ya está en uso por otro proceso. Elija otro."
            continue
        fi
        PUERTO_SELECCIONADO="$puerto"
        break
    done
}

###############################################################################
# listar_versiones_apt <paquete>  -> deja el resultado en VERSION_SELECCIONADA
# Consulta versiones REALES del repositorio (no están "quemadas" en el script)
###############################################################################
listar_versiones_apt() {
    local paquete="$1"
    local -a versiones

    log_info "Consultando versiones disponibles de '$paquete' en los repositorios..."
    apt-get update -qq

    mapfile -t versiones < <(apt-cache madison "$paquete" | awk '{print $3}' | sort -Vru | uniq)

    if [[ ${#versiones[@]} -eq 0 ]]; then
        log_err "No se encontraron versiones para '$paquete'. Verifique los repositorios."
        VERSION_SELECCIONADA=""
        return 1
    fi

    echo "Versiones disponibles para $paquete:"
    local i=1 v
    for v in "${versiones[@]}"; do
        echo "  $i) $v"
        ((i++))
    done
    echo "  0) Cancelar"

    local opcion
    while true; do
        read -rp "Seleccione una versión [0-${#versiones[@]}]: " opcion
        if [[ "$opcion" == "0" ]]; then
            VERSION_SELECCIONADA=""
            return 1
        fi
        if [[ "$opcion" =~ ^[0-9]+$ ]] && (( opcion >= 1 && opcion <= ${#versiones[@]} )); then
            VERSION_SELECCIONADA="${versiones[$((opcion-1))]}"
            return 0
        fi
        log_err "Opción inválida."
    done
}

###############################################################################
# listar_versiones_tomcat <major: 9|10>  -> deja el resultado en VERSION_SELECCIONADA
# Consulta dinámicamente el índice de archive.apache.org (LTS=9, Desarrollo=10)
###############################################################################
listar_versiones_tomcat() {
    local major="$1"
    local -a versiones

    log_info "Consultando versiones de Tomcat ${major}.x en archive.apache.org..."
    mapfile -t versiones < <(curl -s "https://archive.apache.org/dist/tomcat/tomcat-${major}/" \
        | grep -oE "v${major}\.[0-9]+\.[0-9]+" | sed 's/^v//' | sort -Vru | uniq)

    if [[ ${#versiones[@]} -eq 0 ]]; then
        log_err "No se pudo consultar el repositorio de Tomcat (revise conexión a internet)."
        return 1
    fi

    echo "Versiones disponibles de Tomcat ${major}:"
    local i=1 v
    for v in "${versiones[@]:0:10}"; do
        echo "  $i) $v"
        ((i++))
    done
    echo "  0) Cancelar"

    local opcion
    read -rp "Seleccione una versión [0-$((i-1))]: " opcion
    if [[ "$opcion" == "0" ]]; then return 1; fi
    if [[ "$opcion" =~ ^[0-9]+$ ]] && (( opcion >= 1 && opcion < i )); then
        VERSION_SELECCIONADA="${versiones[$((opcion-1))]}"
        return 0
    fi
    log_err "Opción inválida."
    return 1
}

###############################################################################
# obtener_puerto_actual_apache -> puerto donde Apache YA está escuchando (0 si no)
###############################################################################
obtener_puerto_actual_apache() {
    if [[ -f /etc/apache2/ports.conf ]]; then
        grep -oP '^Listen \K[0-9]+' /etc/apache2/ports.conf | head -1 || echo 0
    else
        echo 0
    fi
}

###############################################################################
# obtener_puerto_actual_nginx -> puerto donde Nginx YA está escuchando (0 si no)
###############################################################################
obtener_puerto_actual_nginx() {
    if [[ -f /etc/nginx/sites-available/default ]]; then
        grep -oP '^\s*listen\s+\K[0-9]+' /etc/nginx/sites-available/default | head -1 || echo 0
    else
        echo 0
    fi
}

###############################################################################
# obtener_puerto_actual_tomcat -> puerto donde Tomcat YA está escuchando (0 si no)
###############################################################################
obtener_puerto_actual_tomcat() {
    if [[ -f /opt/tomcat/conf/server.xml ]]; then
        grep -oP 'port="\K[0-9]+(?="\s+protocol="HTTP/1.1")' /opt/tomcat/conf/server.xml | head -1 || echo 0
    else
        echo 0
    fi
}

###############################################################################
# crear_usuario_dedicado <usuario> <directorio_home>
# Usuario de sistema, sin shell de login, dueño exclusivo de su directorio
###############################################################################
crear_usuario_dedicado() {
    local usuario="$1"
    local home_dir="$2"

    if id "$usuario" &>/dev/null; then
        log_info "El usuario '$usuario' ya existe."
    else
        useradd --system --no-create-home --home-dir "$home_dir" \
            --shell /usr/sbin/nologin "$usuario"
        log_ok "Usuario dedicado '$usuario' creado (sin shell, sin login)."
    fi

    mkdir -p "$home_dir"
    chown -R "${usuario}:${usuario}" "$home_dir"
    chmod -R 750 "$home_dir"
}

###############################################################################
# generar_index <servicio> <version> <puerto> <docroot>
###############################################################################
generar_index() {
    local servicio="$1" version="$2" puerto="$3" docroot="$4"
    mkdir -p "$docroot"
    cat > "${docroot}/index.html" <<EOF
<!DOCTYPE html>
<html lang="es">
<head><meta charset="UTF-8"><title>${servicio}</title></head>
<body>
    <h1>Servidor: ${servicio} - Versión: ${version} - Puerto: ${puerto}</h1>
</body>
</html>
EOF
}

###############################################################################
# configurar_firewall <puerto>
# Abre SOLO el puerto elegido para HTTP y cierra los puertos HTTP por defecto
###############################################################################
configurar_firewall() {
    local puerto="$1"
    command -v ufw &>/dev/null || apt-get install -y -qq ufw

    local p
    for p in 80 8080 8888; do
        if [[ "$p" != "$puerto" ]]; then
            ufw delete allow "${p}/tcp" &>/dev/null
        fi
    done
    ufw allow "${puerto}/tcp" &>/dev/null
    yes | ufw enable &>/dev/null
    log_ok "UFW: únicamente el puerto ${puerto}/tcp permitido para HTTP."
}

###############################################################################
# esperar_puerto_activo <puerto> [tiempo_max_seg=15]
# Espera hasta que el puerto esté escuchando antes de darlo por fallido.
# Evita falsos negativos por tiempo de arranque (notorio en Tomcat/JVM,
# que tarda más que Apache/Nginx en terminar de inicializar).
###############################################################################
esperar_puerto_activo() {
    local puerto="$1"
    local maximo="${2:-15}"
    local intento=0
    while (( intento < maximo )); do
        if ss -ltn "( sport = :$puerto )" 2>/dev/null | grep -q ":$puerto"; then
            return 0
        fi
        sleep 1
        ((intento++))
    done
    log_warn "El servicio no respondió en el puerto $puerto tras ${maximo}s de espera."
    return 1
}

###############################################################################
# probar_headers_http <puerto>
###############################################################################
probar_headers_http() {
    local puerto="$1"
    esperar_puerto_activo "$puerto" 15
    log_info "Resultado de 'curl -I' contra el servicio local:"
    curl -sI "http://localhost:${puerto}/" || log_err "No se pudo conectar al puerto ${puerto}."
}

###############################################################################
# ================== APACHE2 =================================================
###############################################################################

configurar_puerto_apache() {
    local puerto="$1"
    local conf="/etc/apache2/ports.conf"

    cp "$conf" "${conf}.bak.$(date +%s)" 2>/dev/null
    sed -i -E "s/^Listen [0-9]+/Listen ${puerto}/" "$conf"
    grep -q "^Listen ${puerto}" "$conf" || echo "Listen ${puerto}" >> "$conf"

    sed -i -E "s/<VirtualHost \*:[0-9]+>/<VirtualHost *:${puerto}>/" \
        /etc/apache2/sites-available/000-default.conf
}

endurecer_apache() {
    local sec_conf="/etc/apache2/conf-available/security.conf"
    if [[ -f "$sec_conf" ]]; then
        sed -i -E "s/^ServerTokens .*/ServerTokens Prod/" "$sec_conf"
        sed -i -E "s/^ServerSignature .*/ServerSignature Off/" "$sec_conf"
        grep -q "^ServerTokens" "$sec_conf" || echo "ServerTokens Prod" >> "$sec_conf"
        grep -q "^ServerSignature" "$sec_conf" || echo "ServerSignature Off" >> "$sec_conf"
        a2enconf security &>/dev/null
    fi
}

restringir_metodos_apache() {
    local conf="/etc/apache2/conf-available/seguridad-metodos.conf"
    cat > "$conf" <<'EOF'
<Location "/">
    <LimitExcept GET POST HEAD>
        Require all denied
    </LimitExcept>
</Location>
TraceEnable off
EOF
    a2enconf seguridad-metodos &>/dev/null
}

agregar_headers_seguridad_apache() {
    a2enmod headers &>/dev/null
    local conf="/etc/apache2/conf-available/security-headers.conf"
    cat > "$conf" <<'EOF'
Header always set X-Frame-Options "SAMEORIGIN"
Header always set X-Content-Type-Options "nosniff"
EOF
    a2enconf security-headers &>/dev/null
}

instalar_apache() {
    local version="$1" puerto="$2"

    if dpkg -l 2>/dev/null | grep -qw apache2; then
        log_warn "Apache2 ya está instalado. Se omite instalación, solo se reconfigura."
    else
        log_info "Instalando apache2=${version} de forma desatendida..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y -qq "apache2=${version}"; then
            log_err "Falló apache2=${version}. Instalando última versión disponible."
            apt-get install -y -qq apache2
        fi
    fi

    configurar_puerto_apache "$puerto"
    endurecer_apache
    restringir_metodos_apache
    agregar_headers_seguridad_apache

    local ver_real
    ver_real=$(apache2 -v 2>/dev/null | head -1 | awk -F/ '{print $2}' | awk '{print $1}')
    generar_index "Apache" "${ver_real:-$version}" "$puerto" "/var/www/html"
    chown -R www-data:www-data /var/www/html

    systemctl enable apache2 --now &>/dev/null
    systemctl restart apache2
    log_ok "Apache2 instalado y escuchando en el puerto $puerto."
}

###############################################################################
# ================== NGINX ====================================================
###############################################################################

configurar_puerto_nginx() {
    local puerto="$1"
    local conf="/etc/nginx/sites-available/default"

    cp "$conf" "${conf}.bak.$(date +%s)" 2>/dev/null
    sed -i -E "s/listen [0-9]+( default_server)?;/listen ${puerto};/g" "$conf"
    sed -i -E "s#root /var/www/html;#root /var/www/nginx-site;#" "$conf"

    grep -q "snippets/seguridad.conf" "$conf" || \
        sed -i "/listen ${puerto};/a\\    include snippets/seguridad.conf;" "$conf"
}

endurecer_nginx() {
    local conf="/etc/nginx/nginx.conf"
    if grep -q "server_tokens" "$conf"; then
        sed -i -E "s/server_tokens .*/server_tokens off;/" "$conf"
    else
        sed -i "/http {/a\\    server_tokens off;" "$conf"
    fi

    mkdir -p /etc/nginx/snippets
    cat > /etc/nginx/snippets/seguridad.conf <<'EOF'
add_header X-Frame-Options "SAMEORIGIN" always;
add_header X-Content-Type-Options "nosniff" always;
if ($request_method !~ ^(GET|HEAD|POST)$) {
    return 405;
}
EOF
}

instalar_nginx() {
    local version="$1" puerto="$2"

    if dpkg -l 2>/dev/null | grep -qw nginx; then
        log_warn "Nginx ya está instalado. Se omite instalación, solo se reconfigura."
    else
        log_info "Instalando nginx=${version} de forma desatendida..."
        export DEBIAN_FRONTEND=noninteractive
        if ! apt-get install -y -qq "nginx=${version}"; then
            log_err "Falló nginx=${version}. Instalando última versión disponible."
            apt-get install -y -qq nginx
        fi
    fi

    crear_usuario_dedicado "nginx-svc" "/var/www/nginx-site"
    configurar_puerto_nginx "$puerto"
    endurecer_nginx

    local ver_real
    ver_real=$(nginx -v 2>&1 | awk -F/ '{print $2}')
    generar_index "Nginx" "${ver_real:-$version}" "$puerto" "/var/www/nginx-site"
    chown -R nginx-svc:nginx-svc /var/www/nginx-site
    chmod -R 750 /var/www/nginx-site

    systemctl enable nginx --now &>/dev/null
    systemctl restart nginx
    log_ok "Nginx instalado y escuchando en el puerto $puerto."
}

###############################################################################
# ================== TOMCAT ===================================================
###############################################################################

configurar_puerto_tomcat() {
    local install_dir="$1" puerto="$2"
    local server_xml="${install_dir}/conf/server.xml"

    cp "$server_xml" "${server_xml}.bak.$(date +%s)"
    sed -i -E "s/port=\"8080\" protocol=\"HTTP\/1.1\"/port=\"${puerto}\" protocol=\"HTTP\/1.1\"/" "$server_xml"
}

endurecer_tomcat() {
    local install_dir="$1"
    local web_xml="${install_dir}/conf/web.xml"

    if ! grep -q "security-constraint" "$web_xml"; then
        sed -i "s#</web-app>#  <security-constraint>\n    <web-resource-collection>\n      <web-resource-name>restringido</web-resource-name>\n      <url-pattern>/*</url-pattern>\n      <http-method>TRACE</http-method>\n      <http-method>TRACK</http-method>\n      <http-method>DELETE</http-method>\n      <http-method>PUT</http-method>\n    </web-resource-collection>\n    <auth-constraint/>\n  </security-constraint>\n</web-app>#" "$web_xml"
    fi
    log_warn "NOTA: ocultar la cabecera 'Server: Apache-Tomcat/x.x' exacta requiere"
    log_warn "reempaquetar catalina.jar (ServerInfo.properties). Se documenta como limitación conocida."
}

crear_servicio_systemd_tomcat() {
    local install_dir="$1" usuario="$2"
    local java_home
    java_home=$(dirname "$(dirname "$(readlink -f "$(command -v java)")")")

    cat > /etc/systemd/system/tomcat.service <<EOF
[Unit]
Description=Apache Tomcat Server
After=network.target

[Service]
Type=forking
User=${usuario}
Group=${usuario}
Environment=JAVA_HOME=${java_home}
Environment=CATALINA_HOME=${install_dir}
Environment=CATALINA_BASE=${install_dir}
ExecStart=${install_dir}/bin/startup.sh
ExecStop=${install_dir}/bin/shutdown.sh
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
}

instalar_tomcat() {
    local major="$1" version="$2" puerto="$3"
    local usuario="tomcat"
    local install_dir="/opt/tomcat"

    if [[ -d "$install_dir" ]]; then
        log_warn "Tomcat ya parece estar instalado en $install_dir. Se omite descarga."
    else
        log_info "Instalando dependencias (JDK)..."
        apt-get update -qq
        apt-get install -y -qq default-jdk curl

        local url="https://archive.apache.org/dist/tomcat/tomcat-${major}/v${version}/bin/apache-tomcat-${version}.tar.gz"
        log_info "Descargando Tomcat ${version}..."
        if ! curl -sSfL "$url" -o /tmp/tomcat.tar.gz; then
            log_err "No se pudo descargar Tomcat ${version}. Verifique la versión/URL."
            return 1
        fi

        mkdir -p "$install_dir"
        tar xzf /tmp/tomcat.tar.gz -C "$install_dir" --strip-components=1
        rm -f /tmp/tomcat.tar.gz
    fi

    crear_usuario_dedicado "$usuario" "$install_dir"
    find "$install_dir/bin" -name "*.sh" -exec chmod +x {} \;

    configurar_puerto_tomcat "$install_dir" "$puerto"
    endurecer_tomcat "$install_dir"
    generar_index "Tomcat" "$version" "$puerto" "${install_dir}/webapps/ROOT"
    chown -R "${usuario}:${usuario}" "$install_dir"
    chmod -R 750 "$install_dir"

    crear_servicio_systemd_tomcat "$install_dir" "$usuario"
    systemctl daemon-reload
    if systemctl is-active --quiet tomcat; then
        # Ya estaba corriendo (reconfiguración): sí conviene reiniciar para
        # que tome el nuevo puerto/config.
        systemctl restart tomcat
    else
        # Primer arranque: "enable --now" ya lo inicia. Un "restart"
        # inmediato después de esto reinicia un proceso que apenas está
        # levantando la JVM (aún sin puerto de shutdown abierto en 8005),
        # lo que producía "Connection refused" en los logs y un falso
        # negativo en la prueba de curl -I por la demora extra.
        systemctl enable tomcat --now &>/dev/null
    fi
    log_ok "Tomcat ${version} instalado y escuchando en el puerto $puerto."
}
