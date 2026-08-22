#!/bin/bash
# ============================================================================
# TAREA 7 - LIBRERÍA DE FUNCIONES (LINUX)
# Infraestructura de Despliegue Seguro e Instalación Híbrida (FTP/Web)
# Refactorización modular: este archivo SOLO contiene funciones.
# El menú principal (tarea7.sh) es el único que las invoca.
#
# NOTA: Este archivo incluye correcciones aplicadas durante las pruebas:
#  - FTP sin --ssl (el repositorio FTP de la Tarea 5 aún no tiene TLS)
#  - Apache: "Listen" del puerto SSL ahora se edita en ports.conf (no en
#    mods-available/ssl.conf, que no tiene esa directiva)
#  - Apache: se habilita mod_headers (además de ssl y rewrite) para que
#    funcione la directiva "Header" del HSTS
#  - Apache: el RewriteRule usa %{SERVER_NAME} en vez de %{HTTP_HOST},
#    porque HTTP_HOST ya incluye el puerto de origen y duplicaba el puerto
#    en la URL de redirección
#  - Nginx: el sed del puerto base ahora ancla el patrón para no corromper
#    la línea "listen [::]:PUERTO default_server;" (IPv6)
#  - Resumen general: antes vivía solo en un array en memoria (RESUMEN_GLOBAL),
#    por lo que se perdía cada vez que se cerraba el script. Ahora se guarda
#    también en un archivo ($RESUMEN_ARCHIVO, definido en tarea7.sh) y
#    persiste entre ejecuciones. Si reinstalas el mismo servicio, se
#    actualiza su línea en vez de duplicarla.
# ============================================================================

# ------------------------------------------------------------------
# 0. DEPENDENCIAS BASE
# ------------------------------------------------------------------
verificar_dependencias() {
    echo -e "${CYAN}[*] Verificando herramientas del sistema (curl, openssl, sha256sum)...${RESET}"
    local faltantes=()
    for cmd in curl openssl sha256sum ss; do
        command -v "$cmd" &>/dev/null || faltantes+=("$cmd")
    done
    if [ ${#faltantes[@]} -gt 0 ]; then
        echo -e "${AMARILLO}[*] Instalando dependencias faltantes: ${faltantes[*]}${RESET}"
        export DEBIAN_FRONTEND=noninteractive
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl openssl coreutils iproute2 >/dev/null 2>&1
    fi
    echo -e "${VERDE}[✓] Dependencias listas.${RESET}"
}

# ------------------------------------------------------------------
# 1. VALIDACIONES
# ------------------------------------------------------------------
validar_puerto_ingresado() {
    local puerto=$1
    if ! [[ "$puerto" =~ ^[0-9]+$ ]] || [ "$puerto" -lt 1 ] || [ "$puerto" -gt 65535 ]; then
        echo -e "${ROJO}[ERROR] El puerto debe ser un número entre 1 y 65535.${RESET}"
        return 1
    fi
    if ss -tuln | grep -q ":$puerto "; then
        echo -e "${ROJO}[ERROR] El puerto $puerto ya está ocupado.${RESET}"
        return 1
    fi
    return 0
}

pedir_puerto() {
    # $1 = texto del prompt -> deja el puerto validado en PUERTO_LEIDO
    local prompt=$1
    local puerto
    while true; do
        read -rp "$prompt" puerto
        if validar_puerto_ingresado "$puerto"; then
            PUERTO_LEIDO=$puerto
            return 0
        fi
    done
}

# ------------------------------------------------------------------
# 2. PKI - CERTIFICADO SSL COMPARTIDO (reprobados.com)
# ------------------------------------------------------------------
generar_certificado_ssl() {
    if [ ! -f "$SSL_DIR/servidor.crt" ]; then
        echo -e "${CYAN}[*] Generando certificado autofirmado para $DOMINIO...${RESET}"
        mkdir -p "$SSL_DIR"
        openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
            -keyout "$SSL_DIR/servidor.key" \
            -out "$SSL_DIR/servidor.crt" \
            -subj "/C=MX/ST=Sinaloa/L=Mochis/O=UAS/OU=FIM/CN=$DOMINIO" >/dev/null 2>&1
        chmod 644 "$SSL_DIR/servidor.key" "$SSL_DIR/servidor.crt"
        echo -e "${VERDE}[✓] Certificado creado en $SSL_DIR${RESET}"
    else
        echo -e "${AMARILLO}[*] Certificado existente reutilizado ($SSL_DIR).${RESET}"
    fi
}

# ------------------------------------------------------------------
# 3. CLIENTE FTP DINÁMICO (navegación + descarga + hash)
# ------------------------------------------------------------------
# Lista subcarpetas (servicios) dentro de http/Linux/ en el FTP privado
ftp_listar_servicios() {
    local url_base="ftp://$FTP_SERVER/general/http/Linux/"
    echo -e "${CYAN}[*] Conectando a $url_base ...${RESET}" >&2
    # FIX: se quitó "-k --ssl" — el repositorio FTP de la Tarea 5 aún no
    # tiene TLS habilitado; navegación en texto plano hacia el repositorio
    # de instaladores (el TLS de la rúbrica se aplica a los 8 SERVICIOS,
    # incluido vsftpd, que se activa más abajo en aplicar_ssl_servicio).
    mapfile -t SERVICIOS_FTP < <(curl -s -l -u "$FTP_USER:$FTP_PASS" "$url_base" | tr -d '\r' | sed '/^$/d')
    if [ ${#SERVICIOS_FTP[@]} -eq 0 ]; then
        echo -e "${ROJO}[!] No se encontraron carpetas de servicio en el repositorio.${RESET}" >&2
        return 1
    fi
    return 0
}

# Lista los binarios (excluye .sha256) dentro de http/Linux/<servicio>/
ftp_listar_versiones() {
    local servicio=$1
    local url="ftp://$FTP_SERVER/general/http/Linux/$servicio/"
    mapfile -t VERSIONES_FTP < <(curl -s -l -u "$FTP_USER:$FTP_PASS" "$url" | tr -d '\r' | grep -v '\.sha256$' | sed '/^$/d')
    if [ ${#VERSIONES_FTP[@]} -eq 0 ]; then
        echo -e "${ROJO}[!] No hay instaladores disponibles para $servicio.${RESET}" >&2
        return 1
    fi
    return 0
}

# Navegación completa: OS/servicio dinámico -> versión -> descarga -> hash
# Deja el binario descargado en PAQUETE_DESCARGADO y confirma el servicio en SERVICIO_ELEGIDO_FTP
navegar_y_descargar_ftp() {
    mkdir -p "$DIR_DESCARGAS"

    if ! ftp_listar_servicios; then
        echo -e "${AMARILLO}[DEBUG] Verifica manualmente: curl -l -u \"$FTP_USER:$FTP_PASS\" \"ftp://$FTP_SERVER/general/http/Linux/\"${RESET}"
        return 1
    fi

    echo -e "${AZUL}--- Servicios disponibles en el repositorio (Linux) ---${RESET}"
    local i=1
    for s in "${SERVICIOS_FTP[@]}"; do
        echo "  $i) $s"
        ((i++))
    done
    local sel_servicio
    read -rp "Selecciona el número del servicio a instalar: " sel_servicio
    if ! [[ "$sel_servicio" =~ ^[0-9]+$ ]] || [ "$sel_servicio" -lt 1 ] || [ "$sel_servicio" -gt ${#SERVICIOS_FTP[@]} ]; then
        echo -e "${ROJO}[ERROR] Selección inválida.${RESET}"
        return 1
    fi
    local servicio="${SERVICIOS_FTP[$((sel_servicio-1))]}"

    if ! ftp_listar_versiones "$servicio"; then
        return 1
    fi

    echo -e "${AZUL}--- Versiones disponibles de $servicio ---${RESET}"
    i=1
    for v in "${VERSIONES_FTP[@]}"; do
        echo "  $i) $v"
        ((i++))
    done
    local sel_version
    read -rp "Selecciona el número de la versión a descargar: " sel_version
    if ! [[ "$sel_version" =~ ^[0-9]+$ ]] || [ "$sel_version" -lt 1 ] || [ "$sel_version" -gt ${#VERSIONES_FTP[@]} ]; then
        echo -e "${ROJO}[ERROR] Selección inválida.${RESET}"
        return 1
    fi
    local archivo_elegido="${VERSIONES_FTP[$((sel_version-1))]}"
    local url_servicio="ftp://$FTP_SERVER/general/http/Linux/$servicio/"

    echo -e "${AMARILLO}[*] Descargando $archivo_elegido y su firma SHA256...${RESET}"
    curl -s -u "$FTP_USER:$FTP_PASS" "$url_servicio$archivo_elegido" -o "$DIR_DESCARGAS/$archivo_elegido"
    curl -s -u "$FTP_USER:$FTP_PASS" "$url_servicio$archivo_elegido.sha256" -o "$DIR_DESCARGAS/$archivo_elegido.sha256"

    if [ ! -s "$DIR_DESCARGAS/$archivo_elegido" ] || [ ! -s "$DIR_DESCARGAS/$archivo_elegido.sha256" ]; then
        echo -e "${ROJO}[X] Error: la descarga del instalador o del hash falló.${RESET}"
        return 1
    fi

    if ! verificar_integridad_hash "$DIR_DESCARGAS/$archivo_elegido" "$DIR_DESCARGAS/$archivo_elegido.sha256"; then
        echo -e "${ROJO}[X] Archivo corrupto. Se aborta la instalación.${RESET}"
        return 1
    fi

    PAQUETE_DESCARGADO="$DIR_DESCARGAS/$archivo_elegido"
    SERVICIO_ELEGIDO_FTP="$servicio"
    return 0
}

# Verificación de integridad SHA256 (recalcula localmente y compara contra el .sha256 del FTP)
verificar_integridad_hash() {
    local archivo=$1
    local archivo_hash=$2
    local hash_esperado hash_calculado
    hash_esperado=$(tr -d '\r\n' < "$archivo_hash" | awk '{print $1}')
    hash_calculado=$(sha256sum "$archivo" | awk '{print $1}')

    if [ "$hash_calculado" == "$hash_esperado" ]; then
        echo -e "${VERDE}[✓] Integridad verificada (SHA256 coincide).${RESET}"
        return 0
    else
        echo -e "${ROJO}[X] SHA256 no coincide. Esperado: $hash_esperado | Calculado: $hash_calculado${RESET}"
        return 1
    fi
}

# ------------------------------------------------------------------
# 4. INSTALACIÓN + CONFIGURACIÓN BASE POR SERVICIO
# ------------------------------------------------------------------
instalar_y_configurar_servicio() {
    local servicio=$1     # Apache | Nginx | Tomcat | vsftpd
    local metodo=$2       # web | ftp
    local puerto=$3
    local paquete=$4      # ruta del .deb/.tar.gz descargado (solo si metodo=ftp)

    local pkg_debian=""
    case $servicio in
        "Apache") pkg_debian="apache2" ;;
        "Nginx")  pkg_debian="nginx" ;;
        "vsftpd") pkg_debian="vsftpd" ;;
        "Tomcat") pkg_debian="tomcat10 tomcat10-admin" ;;
    esac

    echo -e "\n${CYAN}>>> Instalando $servicio (Origen: $metodo)...${RESET}"

    if [ "$metodo" == "web" ]; then
        apt-get update -qq && apt-get install -y $pkg_debian -qq >/dev/null 2>&1
    else
        case "$paquete" in
            *.deb)
                dpkg -i "$paquete" >/dev/null 2>&1
                apt-get install -f -y -qq >/dev/null 2>&1
                ;;
            *.tar.gz|*.tgz)
                tar -xzf "$paquete" -C /opt/
                ;;
            *)
                echo -e "${AMARILLO}[!] Formato de paquete no reconocido ($paquete), se omite instalación binaria.${RESET}"
                ;;
        esac
    fi

    case $servicio in
        "Apache")
            sed -i "s/^Listen .*/Listen $puerto/g" /etc/apache2/ports.conf
            sed -i "s/<VirtualHost \*:[0-9]*>/<VirtualHost *:$puerto>/g" /etc/apache2/sites-available/000-default.conf
            rm -f /var/www/html/index*
            echo "<!DOCTYPE html><html><head><meta charset='UTF-8'></head><body><h1>[✓] UAS-FIM: $servicio activo en puerto $puerto</h1></body></html>" > /var/www/html/index.html
            systemctl restart apache2
            ;;
        "Nginx")
            # FIX: el patrón anterior "listen [0-9]*" hacía match también con
            # la línea IPv6 "listen [::]:PUERTO default_server;" (cero dígitos
            # cuentan como match), dejando "listen 9082[::]:8082" — puerto
            # inválido. Ahora se ancla al inicio de línea y exige al menos
            # un dígito, preservando el resto de la línea (incl. "[::]").
            sed -i "s/^\(\s*listen\) [0-9]\+\( default_server\)\?;/\1 $puerto\2;/g" /etc/nginx/sites-enabled/default
            rm -f /var/www/html/index*
            echo "<!DOCTYPE html><html><head><meta charset='UTF-8'></head><body><h1>[✓] UAS-FIM: $servicio activo en puerto $puerto</h1></body></html>" > /var/www/html/index.html
            systemctl restart nginx
            ;;
        "Tomcat")
            sed -i "s/port=\"8080\"/port=\"$puerto\"/g" /etc/tomcat10/server.xml
            mkdir -p /var/lib/tomcat10/webapps/ROOT
            rm -f /var/lib/tomcat10/webapps/ROOT/index*
            echo "<!DOCTYPE html><html><head><meta charset='UTF-8'></head><body><h1>[✓] UAS-FIM: $servicio activo en puerto $puerto</h1></body></html>" > /var/lib/tomcat10/webapps/ROOT/index.html
            systemctl restart tomcat10
            ;;
        "vsftpd")
            grep -q "^listen_port" /etc/vsftpd.conf && sed -i "s/^listen_port=.*/listen_port=$puerto/g" /etc/vsftpd.conf || echo "listen_port=$puerto" >> /etc/vsftpd.conf
            systemctl restart vsftpd
            ;;
    esac
    echo -e "${VERDE}[✓] Configuración base de $servicio lista (puerto $puerto).${RESET}"
}

# ------------------------------------------------------------------
# 5. CIFRADO SSL/TLS + REDIRECCIÓN HTTPS/HSTS POR SERVICIO
# ------------------------------------------------------------------
aplicar_ssl_servicio() {
    local servicio=$1
    local puerto_http=$2

    read -rp "¿Desea activar SSL en este servicio? [S/N]: " activar_ssl
    if [[ ! "$activar_ssl" =~ ^[Ss]$ ]]; then
        PUERTO_SSL_ACTIVO="Ninguno"
        return 0
    fi

    pedir_puerto "Ingresa el puerto SEGURO (SSL/TLS) a utilizar (ej. 443, 8443): "
    local puerto_ssl=$PUERTO_LEIDO
    PUERTO_SSL_ACTIVO=$puerto_ssl
    generar_certificado_ssl

    case $servicio in
        "Apache")
            # FIX: se agrega "headers" — sin este módulo, la directiva
            # "Header" (usada para el HSTS) truena con
            # "Invalid command 'Header'" y Apache no arranca.
            a2enmod ssl rewrite headers >/dev/null 2>&1
            cat <<EOF > /etc/apache2/sites-available/default-ssl.conf
<VirtualHost *:$puerto_ssl>
    ServerName $DOMINIO
    DocumentRoot /var/www/html
    SSLEngine on
    SSLCertificateFile $SSL_DIR/servidor.crt
    SSLCertificateKeyFile $SSL_DIR/servidor.key
    Header always set Strict-Transport-Security "max-age=31536000; includeSubDomains"
</VirtualHost>
EOF
            # FIX: "Listen 443" vive en ports.conf, NO en mods-available/ssl.conf
            # (ese archivo no contiene esa directiva, por lo que el sed original
            # no encontraba nada que reemplazar y el puerto SSL nunca se abría).
            sed -i "s/Listen 443/Listen $puerto_ssl/g" /etc/apache2/ports.conf
            a2ensite default-ssl >/dev/null 2>&1
            # FIX: se usa %{SERVER_NAME} en vez de %{HTTP_HOST}. HTTP_HOST ya
            # incluye el puerto de origen cuando no es el estándar (80/443),
            # lo que duplicaba el puerto en la URL de redirección
            # (ej. "https://IP:9081:9444/" en vez de "https://IP:9444/").
            sed -i "/VirtualHost \*:$puerto_http/a \\\tRewriteEngine On\n\tRewriteCond %{HTTPS} off\n\tRewriteRule ^(.*)$ https://%{SERVER_NAME}:$puerto_ssl%{REQUEST_URI} [L,R=301]" /etc/apache2/sites-available/000-default.conf
            systemctl restart apache2
            ;;
        "Nginx")
            cat <<EOF > /etc/nginx/sites-enabled/default
server {
    listen $puerto_http;
    server_name $DOMINIO;
    return 301 https://\$host:$puerto_ssl\$request_uri;
}
server {
    listen $puerto_ssl ssl;
    server_name $DOMINIO;
    ssl_certificate $SSL_DIR/servidor.crt;
    ssl_certificate_key $SSL_DIR/servidor.key;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    location / {
        root /var/www/html;
        index index.html index.nginx-debian.html;
    }
}
EOF
            systemctl restart nginx
            ;;
        "Tomcat")
            if ! grep -q "port=\"$puerto_ssl\"" /etc/tomcat10/server.xml; then
                sed -i "/<\/Service>/i \\    <Connector port=\"$puerto_ssl\" protocol=\"org.apache.coyote.http11.Http11NioProtocol\" maxThreads=\"150\" SSLEnabled=\"true\" scheme=\"https\" secure=\"true\" clientAuth=\"false\" sslProtocol=\"TLS\">\n      <SSLHostConfig>\n        <Certificate certificateFile=\"$SSL_DIR/servidor.crt\" certificateKeyFile=\"$SSL_DIR/servidor.key\" type=\"RSA\" />\n      </SSLHostConfig>\n    </Connector>" /etc/tomcat10/server.xml
            fi
            systemctl restart tomcat10
            ;;
        "vsftpd")
            # FTPS: túnel SSL en canal de control y de datos (implícito sobre el puerto ya escuchado)
            # FIX: se quitó "ssl_tlsv1_2=YES" — en el build de vsftpd 3.0.5 de
            # Ubuntu esa directiva no es reconocida ("500 OOPS: unrecognised
            # variable in config file: ssl_tlsv1_2") y hace que vsftpd falle
            # al arrancar (el servicio queda "vivo" un instante pero nunca
            # llega a escuchar). No es indispensable: con ssl_enable=YES +
            # force_local_data_ssl/force_local_logins_ssl el canal ya queda
            # cifrado y vsftpd sigue negociando TLS moderno por defecto.
            grep -q "^ssl_enable" /etc/vsftpd.conf || {
                {
                    echo "ssl_enable=YES"
                    echo "allow_anon_ssl=NO"
                    echo "force_local_data_ssl=YES"
                    echo "force_local_logins_ssl=YES"
                    echo "ssl_sslv2=NO"
                    echo "ssl_sslv3=NO"
                    echo "rsa_cert_file=$SSL_DIR/servidor.crt"
                    echo "rsa_private_key_file=$SSL_DIR/servidor.key"
                } >> /etc/vsftpd.conf
            }
            systemctl restart vsftpd
            ;;
    esac
    echo -e "${VERDE}[✓] SSL/TLS activado en $servicio (puerto $puerto_ssl).${RESET}"
}

# ------------------------------------------------------------------
# 6. VERIFICACIÓN AUTOMATIZADA Y RESUMEN
# ------------------------------------------------------------------
realizar_resumen_instalacion() {
    local serv=$1
    local pto=$2

    if [ "$serv" == "Tomcat" ]; then
        echo -e "${AMARILLO}[*] Esperando 10s a que Tomcat/Java levante el servicio...${RESET}"
        sleep 10
    fi

    local p_name="${serv,,}"
    [[ "$serv" == "Apache" ]] && p_name="apache2"
    [[ "$serv" == "Tomcat" ]] && p_name="java"

    echo -e "\n${AZUL}=========================================${RESET}"
    echo -e "${AZUL}        RESUMEN DE INSTALACIÓN - $serv${RESET}"
    echo -e "${AZUL}=========================================${RESET}"

    echo -ne "Estado del proceso:        "
    pgrep "$p_name" >/dev/null && echo -e "${VERDE}OK${RESET}" || echo -e "${ROJO}FAIL${RESET}"

    echo -ne "Puerto de escucha ($pto):   "
    ss -tuln | grep -q ":$pto " && echo -e "${VERDE}OK${RESET}" || echo -e "${ROJO}CERRADO${RESET}"

    echo -ne "Cifrado SSL/TLS:            "
    if [ "$PUERTO_SSL_ACTIVO" != "Ninguno" ]; then
        if [ "$serv" == "vsftpd" ]; then
            grep -q "ssl_enable=YES" /etc/vsftpd.conf && echo -e "${VERDE}ACTIVO (FTPS, puerto $PUERTO_SSL_ACTIVO)${RESET}" || echo -e "${ROJO}FALLÓ${RESET}"
        else
            ss -tuln | grep -q ":$PUERTO_SSL_ACTIVO " && echo -e "${VERDE}ACTIVO (puerto $PUERTO_SSL_ACTIVO)${RESET}" || echo -e "${ROJO}FALLÓ${RESET}"
        fi
    else
        echo -e "${AMARILLO}OMITIDO${RESET}"
    fi

    echo -ne "Certificado www.reprobados: "
    [ -f "$SSL_DIR/servidor.crt" ] && echo -e "${VERDE}PRESENTE${RESET}" || echo -e "${AMARILLO}N/A${RESET}"
    echo -e "${AZUL}-----------------------------------------${RESET}"

    # FIX: se guarda también en disco (no solo en el array en memoria) para
    # que el resumen sobreviva a cerrar y reabrir el script. Si el servicio
    # ya tenía una línea previa, se reemplaza en vez de duplicarse.
    RESUMEN_GLOBAL+=("$serv | puerto $pto | SSL: $PUERTO_SSL_ACTIVO")
    if [ -n "$RESUMEN_ARCHIVO" ]; then
        touch "$RESUMEN_ARCHIVO"
        grep -v "^$serv |" "$RESUMEN_ARCHIVO" > "$RESUMEN_ARCHIVO.tmp" 2>/dev/null
        mv "$RESUMEN_ARCHIVO.tmp" "$RESUMEN_ARCHIVO"
        echo "$serv | puerto $pto | SSL: $PUERTO_SSL_ACTIVO" >> "$RESUMEN_ARCHIVO"
    fi
}

mostrar_resumen_global() {
    echo -e "\n${AZUL}########## RESUMEN GENERAL DE LA PRÁCTICA 7 ##########${RESET}"
    if [ -n "$RESUMEN_ARCHIVO" ] && [ -s "$RESUMEN_ARCHIVO" ]; then
        while IFS= read -r linea; do
            echo -e "${VERDE}- $linea${RESET}"
        done < "$RESUMEN_ARCHIVO"
    else
        echo -e "${AMARILLO}Aún no se ha instalado ningún servicio (ni en esta sesión ni en sesiones anteriores).${RESET}"
    fi
    echo -e "${AZUL}#######################################################${RESET}"
}
