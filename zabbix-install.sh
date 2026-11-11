#!/usr/bin/env bash
#
# zabbix-install.sh
# Instalador interactivo de Zabbix para despliegues en clientes.
#
#   Opcion 1 : Instalacion nativa distribuida sobre Debian 13 (Trixie)
#               - Nodo Servidor Zabbix (server + frontend nginx/PHP-FPM + agent2)
#               - Nodo Base de Datos   (PostgreSQL 17 + TimescaleDB)
#
#   Opcion 2 : Instalacion contenerizada con Docker + Docker Compose
#
# Version: 1.0.0
#
# Uso:
#   sudo ./zabbix-install.sh
#
# Variables de entorno utiles:
#   ZBX_NO_COLOR=1     desactiva los colores
#   ZBX_ASSUME_YES=1   no pide confirmaciones (despliegue desatendido)
#
# ---------------------------------------------------------------------------

set -Eeuo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# Constantes
# ---------------------------------------------------------------------------

readonly SCRIPT_NAME="zabbix-install.sh"
readonly SCRIPT_VERSION="1.0.0"

# Versiones de Zabbix con paquete oficial para Debian 13 (trixie).
# 7.2 NO se incluye: el repositorio oficial no publica build para trixie.
readonly -a ZBX_VERSIONS=("7.0" "7.4" "8.0")

# Ruta base del repositorio oficial por version.
# 7.0 usa /zabbix/7.0/debian/ ; 7.4 y 8.0 usan /zabbix/<ver>/stable/debian/
# (la rama 'release' solo publica metapaquetes 'all', sin binarios amd64)
readonly ZBX_REPO_BASE_70="https://repo.zabbix.com/zabbix/7.0/debian"
readonly ZBX_REPO_BASE_74="https://repo.zabbix.com/zabbix/7.4/stable/debian"
readonly ZBX_REPO_BASE_80="https://repo.zabbix.com/zabbix/8.0/stable/debian"

readonly DEBIAN_CODENAME="trixie"
readonly DEBIAN_VERSION="13"
readonly PG_VERSION="17"

# Imagen de TimescaleDB para Docker (PostgreSQL 17, Community Edition con compresion)
# La imagen de TimescaleDB debe ser compatible con la version de Zabbix.
ts_image_tag() {
    printf 'timescale/timescaledb:%s-pg17' "$(zbx_max_ts_version "$1")"
}

readonly ZBX_WEB_PORT_DEFAULT=80
readonly ZBX_TRAPPER_PORT=10051
readonly ZBX_AGENT_PORT=10050

# ---------------------------------------------------------------------------
# Variables globales
# ---------------------------------------------------------------------------

ZBX_VERSION=""
ZBX_DB_HOST=""
ZBX_SERVER_IP=""
ZBX_DB_NAME="zabbix"
ZBX_DB_USER="zabbix"
ZBX_DB_PASSWORD=""
ZBX_DB_PORT="5432"
ZBX_TIMEZONE="Europe/Madrid"
ZBX_WEB_PORT="${ZBX_WEB_PORT_DEFAULT}"
ZBX_SERVER_NAME=""
ZBX_HOSTNAME=""
ZBX_DOCKER_DIR="$(pwd)"
ZBX_LOG_FILE="/var/log/zabbix-install.log"

CPU_CORES=1
RAM_MB=2048

ANSWER=""
CHOICE=""
YESNO=""

# ---------------------------------------------------------------------------
# Presentacion (colores)
# ---------------------------------------------------------------------------

if [[ -t 1 && -z "${ZBX_NO_COLOR:-}" && "${TERM:-dumb}" != "dumb" ]]; then
    C_RESET=$'\033[0m'; C_BOLD=$'\033[1m'; C_DIM=$'\033[2m'
    C_RED=$'\033[0;31m';   C_GREEN=$'\033[0;32m'; C_YELLOW=$'\033[0;33m'
    C_BLUE=$'\033[0;34m';  C_CYAN=$'\033[0;36m'
else
    C_RESET=""; C_BOLD=""; C_DIM=""
    C_RED=""; C_GREEN=""; C_YELLOW=""; C_BLUE=""; C_CYAN=""
fi

ts() { date '+%Y-%m-%d %H:%M:%S'; }

log_to_file() {
    local msg="$1"
    [[ -d "$(dirname "${ZBX_LOG_FILE}")" ]] || return 0
    printf '%s | %s\n' "$(ts)" "${msg}" >>"${ZBX_LOG_FILE}" 2>/dev/null || true
}

log_info()     { local m="[INFO]  $*"; printf '%s%s%s\n' "${C_BLUE}"   "${m}" "${C_RESET}"; log_to_file "${m}"; }
log_ok()       { local m="[ OK ]  $*"; printf '%s%s%s\n' "${C_GREEN}"  "${m}" "${C_RESET}"; log_to_file "${m}"; }
log_warn()     { local m="[WARN]  $*"; printf '%s%s%s\n' "${C_YELLOW}" "${m}" "${C_RESET}"; log_to_file "${m}"; }
log_error()    { local m="[ERROR] $*"; printf '%s%s%s\n' "${C_RED}"    "${m}" "${C_RESET}" >&2; log_to_file "${m}"; }
log_step()     { local m="==>    $*"; printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "${m}" "${C_RESET}"; log_to_file "${m}"; }
log_info_dim() { printf '%s%s%s\n' "${C_DIM}" "[INFO]  $*" "${C_RESET}"; log_to_file "[INFO]  $*"; }

die() { log_error "$*"; exit 1; }

on_error() {
    local exit_code=$?
    local line="${1:-?}"
    local cmd="${2:-?}"
    log_error "Fallo en la linea ${line} (codigo ${exit_code})."
    log_error "Comando: ${cmd}"
    log_error "Revise ${ZBX_LOG_FILE} para el detalle."
    exit "${exit_code}"
}
trap 'on_error "${LINENO}" "${BASH_COMMAND}"' ERR

section() {
    printf '\n%s%s%s\n' "${C_BOLD}${C_BLUE}" "================================================================================" "${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_BLUE}" "$1" "${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_BLUE}" "================================================================================" "${C_RESET}"
}

# ---------------------------------------------------------------------------
# Utilidades
# ---------------------------------------------------------------------------

require_root() {
    [[ "$(id -u)" -eq 0 ]] || die "Este script necesita ejecutarse como root. Use: sudo ${SCRIPT_NAME}"
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

detect_hardware() {
    CPU_CORES="$(nproc 2>/dev/null || echo 2)"
    local kb
    kb="$(awk '/MemTotal:/ {print $2}' /proc/meminfo 2>/dev/null || echo 2097152)"
    RAM_MB=$(( kb / 1024 ))
    [[ "${RAM_MB}" -lt 512 ]] && RAM_MB=512
    log_info_dim "Hardware detectado: ${CPU_CORES} vCPU / ${RAM_MB} MB RAM"
}

detect_local_ip() {
    local ip=""
    if have_cmd ip; then
        ip="$(ip -4 -o addr show scope global 2>/dev/null | awk '{print $4}' | cut -d/ -f1 | head -n 1)"
    fi
    if [[ -z "${ip}" && -r /etc/hosts ]]; then
        ip="$(awk '/^[0-9]+\./ && $1 != "127.0.0.1" {print $1; exit}' /etc/hosts)"
    fi
    [[ -z "${ip}" ]] && ip="127.0.0.1"
    printf '%s' "${ip}"
}

validate_ipv4() {
    local ip="$1" o
    [[ "${ip}" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]] || return 1
    IFS='.' read -r -a _oct <<<"${ip}"
    for o in "${_oct[@]}"; do
        [[ "${o}" =~ ^0[0-9]+$ ]] && return 1
        (( 10#${o} <= 255 )) || return 1
    done
    return 0
}

# ---------------------------------------------------------------------------
# Entrada del usuario (resultado en ANSWER / CHOICE / YESNO)
# ---------------------------------------------------------------------------

ask() {
    local prompt="$1" default="${2:-}"
    if [[ -n "${default}" ]]; then
        read -r -p "${C_CYAN}${prompt} ${C_RESET}[${default}]: " ANSWER
        ANSWER="${ANSWER:-${default}}"
    else
        read -r -p "${C_CYAN}${prompt} ${C_RESET}: " ANSWER
    fi
}

ask_required() {
    while true; do
        ask "$1"
        [[ -n "${ANSWER}" ]] && return 0
        log_warn "El valor no puede estar vacio."
    done
}

ask_yes_no() {
    local default="${2:-s}"
    while true; do
        ask "$1 (s/n)" "${default}"
        case "${ANSWER,,}" in
            s|si|yes|y) YESNO="s"; return 0 ;;
            n|no)        YESNO="n"; return 0 ;;
            *) log_warn "Responda 's' o 'n'." ;;
        esac
    done
}

ask_password() {
    local pwd pwd2
    while true; do
        read -r -s -p "${C_CYAN}$1 ${C_RESET}: " pwd; echo
        read -r -s -p "${C_CYAN}$1 (repetir) ${C_RESET}: " pwd2; echo
        if [[ "${pwd}" != "${pwd2}" ]]; then
            log_warn "Las contrasenas no coinciden."
            continue
        fi
        if [[ "${#pwd}" -lt 12 ]]; then
            log_warn "La contrasena debe tener al menos 12 caracteres."
            continue
        fi
        if [[ ! "${pwd}" =~ ^[A-Za-z0-9._~!@%+=:-]+$ ]]; then
            log_warn "Caracteres no permitidos. Use letras, digitos y . _ ~ ! @ % + = : -"
            continue
        fi
        ANSWER="${pwd}"
        return 0
    done
}

ask_ipv4() {
    local default="${2:-}"
    while true; do
        ask "$1" "${default}"
        if validate_ipv4 "${ANSWER}"; then
            return 0
        fi
        log_warn "Direccion IPv4 no valida: ${ANSWER}"
    done
}

ask_menu() {
    local prompt="$1"; shift
    local -a options=("$@")
    local i
    printf '\n%s%s%s\n' "${C_BOLD}" "${prompt}" "${C_RESET}"
    for i in "${!options[@]}"; do
        printf '  %s%d%s) %s\n' "${C_GREEN}" "$((i + 1))" "${C_RESET}" "${options[$i]}"
    done
    while true; do
        read -r -p "${C_CYAN}Opcion${C_RESET}: " CHOICE
        [[ "${CHOICE}" =~ ^[0-9]+$ ]] || { log_warn "Introduzca un numero."; continue; }
        if (( CHOICE >= 1 && CHOICE <= ${#options[@]} )); then
            return 0
        fi
        log_warn "Opcion fuera de rango."
    done
}

confirm() {
    local default="${2:-s}"
    if [[ "${ZBX_ASSUME_YES:-0}" == "1" ]]; then
        return 0
    fi
    ask_yes_no "$1" "${default}"
    [[ "${YESNO}" == "s" ]]
}

# ---------------------------------------------------------------------------
# Comprobaciones del sistema
# ---------------------------------------------------------------------------

check_os() {
    [[ -r /etc/os-release ]] || die "No se puede leer /etc/os-release."
    # shellcheck disable=SC1091
    . /etc/os-release
    if [[ "${ID:-}" != "debian" ]]; then
        log_warn "Este script esta disenado para Debian. Distribucion detectada: ${PRETTY_NAME:-desconocida}"
        confirm "Continuar de todos modos?" "n" || die "Instalacion cancelada."
        return 0
    fi
    if [[ "${VERSION_ID:-}" != "${DEBIAN_VERSION}" ]]; then
        log_warn "Version de Debian detectada: ${VERSION_ID} (${VERSION_CODENAME:-?}). Se recomienda ${DEBIAN_VERSION} (${DEBIAN_CODENAME})."
        confirm "Continuar de todos modos?" "n" || die "Instalacion cancelada."
    else
        log_ok "Debian ${VERSION_ID} (${VERSION_CODENAME}) detectado."
    fi
}

install_base_packages() {
    log_step "Instalando paquetes base"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq || die "No se pudieron actualizar los indices de APT. Revise la conectividad y las fuentes."
    # Paquetes imprescindibles: sin ellos no se pueden anadir repositorios externos.
    apt-get install -y -qq --no-install-recommends \
        ca-certificates curl wget gnupg lsb-release apt-transport-https \
        >/dev/null || die "Fallo al instalar los paquetes base imprescindibles."
    # Paquetes de apoyo: su ausencia no debe abortar la instalacion.
    apt-get install -y -qq --no-install-recommends \
        sudo rsync net-tools iproute2 locales tzdata less procps >/dev/null \
        || log_warn "Algún paquete de apoyo no se pudo instalar; la instalacion continua."
    local locales
    locales="$(locale -a 2>/dev/null || true)"
    if ! grep -qi 'en_US.utf8' <<<"${locales}"; then
        log_info_dim "Generando locale en_US.UTF-8"
        sed -i 's/^# *en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
        locale-gen en_US.UTF-8 >/dev/null 2>&1 || true
    fi
    log_ok "Paquetes base instalados."
}

set_timezone() {
    log_step "Configurando zona horaria: ${ZBX_TIMEZONE}"
    if have_cmd timedatectl; then
        timedatectl set-timezone "${ZBX_TIMEZONE}" >/dev/null 2>&1 || log_warn "No se pudo ajustar la zona horaria del sistema."
    fi
    ln -sf "/usr/share/zoneinfo/${ZBX_TIMEZONE}" /etc/localtime
    echo "${ZBX_TIMEZONE}" >/etc/timezone
    log_ok "Zona horaria aplicada."
}

# ---------------------------------------------------------------------------
# Repositorio oficial de Zabbix
# ---------------------------------------------------------------------------

# Version maxima de TimescaleDB aceptada por cada rama de Zabbix.
# El servidor Zabbix rechaza las versiones mas nuevas ("TimescaleDB version is
# too new"): 7.0 y 8.0 admiten hasta 2.29.x y 7.4 hasta 2.30.x.
zbx_max_ts_version() {
    case "$1" in
        7.0) printf '%s' "2.29.2" ;;
        7.4) printf '%s' "2.30.2" ;;
        8.0) printf '%s' "2.29.2" ;;
        *)   printf '%s' "2.29.2" ;;
    esac
}

zbx_repo_base() {
    case "$1" in
        7.0) printf '%s' "${ZBX_REPO_BASE_70}" ;;
        7.4) printf '%s' "${ZBX_REPO_BASE_74}" ;;
        8.0) printf '%s' "${ZBX_REPO_BASE_80}" ;;
        *)   die "Version de Zabbix no soportada: $1" ;;
    esac
}

install_zabbix_repo() {
    local ver="$1"
    local base
    base="$(zbx_repo_base "${ver}")"
    local tmpdir
    tmpdir="$(mktemp -d)"

    log_step "Configurando repositorio oficial de Zabbix ${ver}"

    # El nombre real del paquete usa la version de Debian (debian13), no el codename.
    # El metapaquete zabbix-release puede estar en la rama 'release' (solo
    # metapaquetes) o en la 'stable' (paquetes amd64): se prueban ambas.
    local -a bases=()
    case "${ver}" in
        7.0) bases=("https://repo.zabbix.com/zabbix/7.0/debian") ;;
        *)   bases=("https://repo.zabbix.com/zabbix/${ver}/release/debian" "${base}") ;;
    esac
    local -a candidates=()
    local b
    for b in "${bases[@]}"; do
        candidates+=(
            "${b}/pool/main/z/zabbix-release/zabbix-release_latest_${ver}+debian${DEBIAN_VERSION}_all.deb"
            "${b}/pool/main/z/zabbix-release/zabbix-release_latest_${ver}+${DEBIAN_CODENAME}_all.deb"
        )
    done
    local url deb=""
    for url in "${candidates[@]}"; do
        log_info_dim "Probando ${url}"
        if curl -fsSL --retry 3 --connect-timeout 20 -o "${tmpdir}/zabbix-release.deb" "${url}" 2>/dev/null; then
            deb="${tmpdir}/zabbix-release.deb"
            break
        fi
    done
    [[ -n "${deb}" ]] || die "No se pudo descargar el paquete zabbix-release para Zabbix ${ver} en ${base}."

    # El paquete instala la clave GPG en /usr/share/keyrings/zabbix.gpg y sus
    # fuentes en formato deb822 (.sources), no en el clásico .list.
    dpkg -i "${deb}" >/dev/null 2>&1 || true
    apt-get install -f -y -qq >/dev/null 2>&1 || true

    # El paquete deja su propia fuente en formato deb822 apuntando a la rama
    # correcta. Se comprueba y, solo si hiciese falta, se escribe a mano.
    local src="/etc/apt/sources.list.d/zabbix.sources"
    if [[ ! -f "${src}" ]]; then
        cat >/etc/apt/sources.list.d/zabbix.list <<ZBX_LIST_EOF
deb [signed-by=/usr/share/keyrings/zabbix.gpg] ${base} ${DEBIAN_CODENAME} main
ZBX_LIST_EOF
    elif ! grep -q "/zabbix/${ver}/" "${src}"; then
        log_warn "La fuente generada por el paquete no apunta a la rama ${ver}; se corrige."
        cat >"${src}" <<ZBX_SRC_EOF
Types: deb
URIs: ${base}
Suites: ${DEBIAN_CODENAME}
Components: main
Signed-By: /usr/share/keyrings/zabbix.gpg
ZBX_SRC_EOF
    fi
    # Se apartan las demas fuentes del paquete (release duplicada, unstable y
    # tools) para que no pueda aparecer otra version de zabbix-server-pgsql.
    mkdir -p /etc/apt/sources.list.d.disabled
    local extra
    for extra in zabbix-release.sources zabbix-unstable.sources zabbix-tools.sources; do
        if [[ -f "/etc/apt/sources.list.d/${extra}" ]]; then
            mv -f "/etc/apt/sources.list.d/${extra}" "/etc/apt/sources.list.d.disabled/${extra}"
        fi
    done

    apt-get update -qq || die "No se pudieron actualizar los indices de APT tras configurar el repositorio de Zabbix."
    local candidate
    candidate="$(apt-cache policy zabbix-server-pgsql 2>/dev/null | awk '/Candidate:/ {print $2}')"
    if [[ -z "${candidate}" || "${candidate}" == "(none)" ]]; then
        die "El repositorio de Zabbix ${ver} no ofrece zabbix-server-pgsql para Debian ${DEBIAN_VERSION}."
    fi
    # El candidato puede llevar prefijo de epoch (1:7.4.13); se compara sin el.
    local candidate_ver="${candidate##*:}"
    if [[ "${candidate_ver}" != "${ver}"* ]]; then
        die "El repositorio ofrece la version ${candidate} pero se ha solicitado la rama ${ver}."
    fi
    rm -rf "${tmpdir}"
    log_ok "Repositorio de Zabbix ${ver} operativo (paquete ${candidate})."
}

# ---------------------------------------------------------------------------
# Helper de configuracion idempotente
# ---------------------------------------------------------------------------

# set_conf <fichero> <clave> <valor>
# Elimina cualquier definicion activa o comentada de la clave y anade la nueva.
set_conf() {
    local file="$1" key="$2" value="$3"
    [[ -f "${file}" ]] || return 1
    sed -i -E "/^[[:space:]]*#?[[:space:]]*${key}=/d" "${file}"
    printf '%s=%s\n' "${key}" "${value}" >>"${file}"
}

# locate_sql_dir: directorio con los scripts SQL de PostgreSQL.
# 7.0 usa /usr/share/zabbix-sql-scripts/postgresql ; 7.2+ usa /usr/share/zabbix/sql-scripts/postgresql
locate_sql_dir() {
    local d
    for d in /usr/share/zabbix/sql-scripts/postgresql /usr/share/zabbix-sql-scripts/postgresql; do
        [[ -d "${d}" ]] && { printf '%s' "${d}"; return 0; }
    done
    return 1
}

# psql como el rol propietario de la base, usando TCP + password.
# Se usa TCP (y no peer auth) para que funcione con cualquier nombre de rol,
# ya que peer auth solo funciona si el rol de BD coincide con el usuario del sistema.
psql_zabbix() {
    PGPASSWORD="${ZBX_DB_PASSWORD}" psql -q -v ON_ERROR_STOP=1 \
        -h 127.0.0.1 -p "${ZBX_DB_PORT}" -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" "$@"
}
# psql como superusuario postgres
psql_super()  { runuser -u postgres -- psql -q -v ON_ERROR_STOP=1 "$@"; }

# ---------------------------------------------------------------------------
# Optimizacion del sistema (comun a ambos nodos)
# ---------------------------------------------------------------------------

opt_sysctl() {
    log_step "Aplicando ajustes de kernel (sysctl)"
    cat >/etc/sysctl.d/99-zabbix-tuning.conf <<'SYSCTL_EOF'
# Ajustes recomendados para Zabbix (instalador Zabbix)
net.core.somaxconn = 4096
net.core.netdev_max_backlog = 8192
net.ipv4.tcp_max_syn_backlog = 8192
net.ipv4.tcp_fin_timeout = 15
net.ipv4.tcp_keepalive_time = 300
net.ipv4.tcp_slow_start_after_idle = 0
net.ipv4.ip_local_port_range = 10240 65535
net.core.rmem_max = 16777216
net.core.wmem_max = 16777216
net.ipv4.tcp_rmem = 4096 87380 16777216
net.ipv4.tcp_wmem = 4096 65536 16777216
fs.file-max = 1048576
fs.inotify.max_user_watches = 524288
vm.swappiness = 10
vm.dirty_background_ratio = 5
vm.dirty_ratio = 20
SYSCTL_EOF
    sysctl --system >/dev/null 2>&1 || log_warn "sysctl --system devolvio un error (algun parametro puede estar restringido)."
    log_ok "Ajustes de kernel aplicados."
}

opt_systemd_limits() {
    log_step "Aumentando limites de sistema para los servicios Zabbix"
    local svc
    for svc in zabbix-server zabbix-agent2 nginx php8.4-fpm postgresql; do
        systemctl cat "${svc}" >/dev/null 2>&1 || continue
        mkdir -p "/etc/systemd/system/${svc}.service.d"
        cat >"/etc/systemd/system/${svc}.service.d/99-zabbix-limits.conf" <<'LIM_EOF'
[Service]
LimitNOFILE=65536
LimitNPROC=65536
LimitCORE=0
LIM_EOF
    done
    systemctl daemon-reload
    log_ok "Limites de sistema ampliados."
}

opt_disable_junk() {
    log_step "Deshabilitando servicios no necesarios"
    local svc
    for svc in avahi-daemon cups bluetooth; do
        if systemctl list-unit-files "${svc}.service" >/dev/null 2>&1 \
           && systemctl cat "${svc}.service" >/dev/null 2>&1; then
            systemctl disable --now "${svc}" >/dev/null 2>&1 || true
            log_info_dim "Servicio ${svc} deshabilitado."
        fi
    done
    log_ok "Servicios no esenciales deshabilitados."
}

# ---------------------------------------------------------------------------
# Firewall
# ---------------------------------------------------------------------------

open_port() {
    local port="$1" proto="${2:-tcp}" src="${3:-any}"
    local ufw_out=""
    if have_cmd ufw; then
        ufw_out="$(ufw status 2>/dev/null || true)"
    fi
    if grep -q "Status: active" <<<"${ufw_out}"; then
        if [[ "${src}" == "any" ]]; then
            ufw allow "${port}/${proto}" >/dev/null 2>&1 || true
        else
            ufw allow from "${src}" to any port "${port}" proto "${proto}" >/dev/null 2>&1 || true
        fi
        ufw --force reload >/dev/null 2>&1 || true
        return 0
    fi
    if have_cmd iptables; then
        if [[ "${src}" == "any" ]]; then
            iptables -I INPUT -p "${proto}" --dport "${port}" -j ACCEPT >/dev/null 2>&1 || true
        else
            iptables -I INPUT -p "${proto}" --dport "${port}" -s "${src}" -j ACCEPT >/dev/null 2>&1 || true
        fi
        return 0
    fi
    log_warn "No se ha encontrado ufw ni iptables: abra el puerto ${port}/${proto} manualmente."
}

# ---------------------------------------------------------------------------
# NODO BASE DE DATOS: PostgreSQL + TimescaleDB
# ---------------------------------------------------------------------------

install_timescaledb_repo() {
    log_step "Configurando repositorio de TimescaleDB"
    local pkg="timescaledb-2-postgresql-${PG_VERSION}"
    # Un candidato real es "Candidate: 2.x.y"; "(none)" significa que no hay paquete.
    # La salida se captura antes de filtrar: con 'set -o pipefail', un 'grep -q'
    # que deja de leer puede devolver 141 (SIGPIPE) y producir un falso negativo.
    local policy
    policy="$(apt-cache policy "${pkg}" 2>/dev/null || true)"
    if grep -qE "Candidate:[[:space:]]*[0-9]" <<<"${policy}"; then
        log_ok "Repositorio de TimescaleDB ya configurado."
        return 0
    fi
    log_info_dim "Configurando la fuente de TimescaleDB (packagecloud)"
    local key="/etc/apt/keyrings/timescale_timescaledb-archive-keyring.gpg"
    install -d -m 0755 /etc/apt/keyrings
    if ! curl -fsSL --retry 3 --connect-timeout 20 https://packagecloud.io/timescale/timescaledb/gpgkey \
            | gpg --dearmor --yes -o "${key}" 2>/dev/null; then
        die "No se pudo descargar la clave GPG de TimescaleDB."
    fi
    chmod 0644 "${key}"
    # Se retiran las fuentes timescales previas: duplicar la misma URL con
    # distintos 'signed-by' hace que apt rechace toda la configuracion.
    local f
    for f in /etc/apt/sources.list.d/timescale*.list /etc/apt/sources.list.d/timescale*.sources; do
        if [[ -f "${f}" ]]; then
            rm -f "${f}"
        fi
    done
    cat >/etc/apt/sources.list.d/timescale_timescaledb.list <<TS_EOF
deb [signed-by=${key}] https://packagecloud.io/timescale/timescaledb/debian/ ${DEBIAN_CODENAME} main
TS_EOF
    local apt_err="/tmp/zabbix-apt-update.err"
    local attempt
    for attempt in 1 2; do
        if ! apt-get update -qq 2>"${apt_err}"; then
            log_warn "apt-get update devolvio un error:"
            while read -r line; do log_warn "  ${line}"; done <"${apt_err}"
        fi
        policy="$(apt-cache policy "${pkg}" 2>/dev/null || true)"
        if grep -qE "Candidate:[[:space:]]*[0-9]" <<<"${policy}"; then
            break
        fi
        # Si el indice no aparece, se descarta el cache de esa fuente y se reintenta.
        log_warn "El indice de TimescaleDB aun no esta disponible; se reintenta (intento ${attempt}/2)."
        rm -f /var/lib/apt/lists/*timescale* 2>/dev/null || true
        apt-get update -qq 2>"${apt_err}" || true
    done
    policy="$(apt-cache policy "${pkg}" 2>/dev/null || true)"
    grep -qE "Candidate:[[:space:]]*[0-9]" <<<"${policy}" \
        || die "No hay paquete ${pkg} disponible para ${DEBIAN_CODENAME}."
    log_ok "Repositorio de TimescaleDB operativo."
}

tune_postgresql() {
    log_step "Ajustando PostgreSQL ${PG_VERSION} para Zabbix"
    local confdir="/etc/postgresql/${PG_VERSION}/main"
    [[ -d "${confdir}" ]] || die "No se encuentra el cluster de PostgreSQL ${PG_VERSION} en ${confdir}."

    # Asegurar include_dir (Debian lo activa por defecto en postgresql.conf)
    if ! grep -qE "^[[:space:]]*include_dir[[:space:]]*=[[:space:]]*'conf.d'" "${confdir}/postgresql.conf"; then
        sed -i -E "s@^#?[[:space:]]*include_dir[[:space:]]*=.*@include_dir = 'conf.d'@" "${confdir}/postgresql.conf" \
            || echo "include_dir = 'conf.d'" >>"${confdir}/postgresql.conf"
    fi

    local shared_buffers eff_cache work_mem maint_wal max_wal
    shared_buffers=$(( RAM_MB / 4 )); (( shared_buffers < 512 )) && shared_buffers=512; (( shared_buffers > 8192 )) && shared_buffers=8192
    eff_cache=$(( RAM_MB / 2 ));       (( eff_cache < 1024 ))   && eff_cache=1024;   (( eff_cache > 16384 )) && eff_cache=16384
    work_mem=64
    maint_wal=1024
    max_wal=4096
    if (( RAM_MB < 4096 )); then work_mem=32; maint_wal=512; max_wal=2048; fi

    install -d -m 0755 "${confdir}/conf.d"
    cat >"${confdir}/conf.d/99-zabbix-tuning.conf" <<PG_EOF
# --- Ajustes generados por zabbix-install.sh ---
# Memoria detectada: ${RAM_MB} MB | vCPU: ${CPU_CORES}

listen_addresses = '*'
port = ${ZBX_DB_PORT}

# Rendimiento
shared_buffers = ${shared_buffers}MB
effective_cache_size = ${eff_cache}MB
work_mem = ${work_mem}MB
maintenance_work_mem = ${maint_wal}MB
default_statistics_target = 100
random_page_cost = 1.1
effective_io_concurrency = 200

# WAL y checkpoints
wal_compression = on
max_wal_size = ${max_wal}MB
min_wal_size = ${maint_wal}MB
checkpoint_timeout = 15min
checkpoint_completion_target = 0.9
wal_buffers = 16MB
synchronous_commit = on

# Conexiones y procesos
max_connections = 200
max_worker_processes = 16
max_parallel_workers = 8
max_parallel_workers_per_gather = 2
max_parallel_maintenance_workers = 4

# Housekeeping / limpieza
autovacuum = on
autovacuum_max_workers = 3
autovacuum_naptime = 60s
autovacuum_vacuum_scale_factor = 0.05
autovacuum_analyze_scale_factor = 0.02

# Registro
log_min_duration_statement = 5000
log_checkpoints = on
log_lock_waits = on
log_temp_files = 0
log_timezone = '${ZBX_TIMEZONE}'
timezone = '${ZBX_TIMEZONE}'

# TimescaleDB
shared_preload_libraries = 'timescaledb'
timescaledb.max_background_workers = 8
timescaledb.telemetry_level = 'off'
PG_EOF
    chmod 0644 "${confdir}/conf.d/99-zabbix-tuning.conf"

    # Base de tuning de TimescaleDB (complementa los valores anteriores)
    if have_cmd timescaledb-tune; then
        runuser -u postgres -- timescaledb-tune --quiet --yes \
            --conf-path="${confdir}/postgresql.conf" >/dev/null 2>&1 || true
        log_info_dim "timescaledb-tune aplicado."
    fi
    log_ok "PostgreSQL optimizado (shared_buffers=${shared_buffers}MB, work_mem=${work_mem}MB)."

    # Reiniciar para que listen_addresses, port y shared_preload_libraries surtan efecto
    systemctl restart "postgresql@${PG_VERSION}-main" >/dev/null 2>&1 \
        || systemctl restart postgresql >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do
        pg_isready -q -h /var/run/postgresql -p "${ZBX_DB_PORT}" && break
        sleep 1
    done
    pg_isready -q -h /var/run/postgresql -p "${ZBX_DB_PORT}" \
        || die "PostgreSQL no responde tras aplicar el tuning en el puerto ${ZBX_DB_PORT}."
}

setup_postgres_cluster() {
    log_step "Arrancando el cluster PostgreSQL ${PG_VERSION}"
    systemctl enable postgresql >/dev/null 2>&1 || true
    local clusters
    clusters="$(pg_lsclusters -h 2>/dev/null | awk '{print $1"/"$2}' || true)"
    if ! grep -qx "${PG_VERSION}/main" <<<"${clusters}"; then
        pg_createcluster "${PG_VERSION}" main --start >/dev/null 2>&1 || true
    fi
    systemctl restart "postgresql${PG_VERSION}-main" >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
    local i
    for i in $(seq 1 30); do
        pg_isready -q -h /var/run/postgresql -p "${ZBX_DB_PORT}" && break
        sleep 1
    done
    pg_isready -q -h /var/run/postgresql -p "${ZBX_DB_PORT}" || die "PostgreSQL no responde en el puerto ${ZBX_DB_PORT}."
    log_ok "Cluster PostgreSQL ${PG_VERSION}/main operativo."
}

setup_db_role_and_database() {
    log_step "Creando rol y base de datos de Zabbix"
    # Usuario de sistema para el rol zabbix (necesario para autenticacion peer)
    if ! id -u zabbix >/dev/null 2>&1; then
        useradd --system --no-create-home --shell /bin/bash zabbix
        log_info_dim "Usuario de sistema 'zabbix' creado."
    fi

    local role_exists db_exists
    role_exists="$(psql_super -tAc "SELECT 1 FROM pg_roles WHERE rolname='${ZBX_DB_USER}'" 2>/dev/null || true)"
    db_exists="$(psql_super -tAc "SELECT 1 FROM pg_database WHERE datname='${ZBX_DB_NAME}'" 2>/dev/null || true)"

    if ! grep -q 1 <<<"${role_exists}"; then
        psql_super -c "CREATE ROLE ${ZBX_DB_USER} LOGIN PASSWORD '${ZBX_DB_PASSWORD}'" >/dev/null
    else
        psql_super -c "ALTER ROLE ${ZBX_DB_USER} WITH LOGIN PASSWORD '${ZBX_DB_PASSWORD}'" >/dev/null
    fi

    if ! grep -q 1 <<<"${db_exists}"; then
        psql_super -c "CREATE DATABASE ${ZBX_DB_NAME} OWNER ${ZBX_DB_USER} ENCODING 'UTF8' TEMPLATE template0" >/dev/null
    fi

    log_ok "Rol '${ZBX_DB_USER}' y base '${ZBX_DB_NAME}' listos."
}

configure_pg_hba() {
    log_step "Configurando pg_hba.conf para el nodo ${ZBX_SERVER_IP}"
    local hba="/etc/postgresql/${PG_VERSION}/main/pg_hba.conf"
    [[ -f "${hba}" ]] || die "No se encuentra ${hba}."
    local entry="host    ${ZBX_DB_NAME}    ${ZBX_DB_USER}    ${ZBX_SERVER_IP}/32    scram-sha-256"
    grep -qF "${ZBX_SERVER_IP}" "${hba}" || printf '%s\n' "${entry}" >>"${hba}"
    systemctl reload "postgresql${PG_VERSION}-main" >/dev/null 2>&1 || systemctl restart postgresql >/dev/null 2>&1 || true
    log_ok "Acceso remoto permitido para ${ZBX_SERVER_IP}."
}

install_db_schema() {
    log_step "Importando el esquema inicial de Zabbix"
    local sqldir
    sqldir="$(locate_sql_dir)" || die "No se encuentra el paquete zabbix-sql-scripts (scripts SQL de PostgreSQL)."
    log_info_dim "Scripts SQL en ${sqldir}"

    # Idempotencia: no importar dos veces
    local schema_exists
    schema_exists="$(psql_super -d "${ZBX_DB_NAME}" -tAc "SELECT 1 FROM pg_tables WHERE schemaname='public' AND tablename='users'" 2>/dev/null || true)"
    if grep -q 1 <<<"${schema_exists}"; then
        log_warn "La base ya contiene el esquema de Zabbix; se omite la importacion."
    else
        log_info "Importando server.sql.gz (puede tardar varios minutos)..."
        zcat "${sqldir}/server.sql.gz" | psql_zabbix >/dev/null \
            || die "Fallo al importar el esquema principal de Zabbix."
        log_ok "Esquema principal importado."
    fi

    # TimescaleDB: extension + hypertables + compresion
    local ts_schema="${sqldir}/timescaledb/schema.sql"
    if [[ -f "${ts_schema}" ]]; then
        log_step "Activando TimescaleDB (hypertables y compresion)"
        # Se indica la version instalada: el default_version del loader puede
        # apuntar a una version cuyo script de instalacion no esta presente.
        local ts_create="CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;"
        if [[ -n "${ts_ver_real:-}" ]]; then
            ts_create="CREATE EXTENSION IF NOT EXISTS timescaledb VERSION '${ts_ver_real}' CASCADE;"
        fi
        psql_super -d "${ZBX_DB_NAME}" -c "${ts_create}" >/dev/null 2>&1 \
            || log_warn "No se pudo crear la extension timescaledb."
        local ts_ext
        ts_ext="$(psql_super -d "${ZBX_DB_NAME}" -tAc "SELECT 1 FROM pg_extension WHERE extname='timescaledb'" 2>/dev/null || true)"
        if grep -q 1 <<<"${ts_ext}"; then
            log_info "Aplicando el esquema de TimescaleDB (conversion a hypertables)..."
            # El esquema oficial crea las hypertables y las politicas de compresion.
            if ! PGPASSWORD="${ZBX_DB_PASSWORD}" psql -q -v ON_ERROR_STOP=1 \
                    -h 127.0.0.1 -p "${ZBX_DB_PORT}" -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" \
                    -f "${ts_schema}" >/dev/null 2>&1; then
                log_warn "El esquema de TimescaleDB fallo como usuario de la BD; se reintenta como superusuario."
                psql_super -d "${ZBX_DB_NAME}" -f "${ts_schema}" >/dev/null 2>&1 \
                    || log_warn "No se pudo aplicar el esquema de TimescaleDB; revise el log del servidor."
            fi
            local ht
            ht="$(psql_super -d "${ZBX_DB_NAME}" -tAc "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public'" 2>/dev/null | tr -d '[:space:]')"
            log_ok "TimescaleDB activo (${ht:-0} hypertables)."
        else
            log_warn "La extension timescaledb no esta disponible; la instalacion continuara sin hypertables."
        fi
    else
        log_warn "No se encuentra ${ts_schema}; se omite la configuracion de TimescaleDB."
    fi
}

install_db_node() {
    section "NODO BASE DE DATOS - PostgreSQL ${PG_VERSION} + TimescaleDB"
    install_base_packages
    set_timezone
    opt_sysctl
    opt_disable_junk

    install_timescaledb_repo

    log_step "Instalando PostgreSQL ${PG_VERSION} y TimescaleDB"
    apt-get install -y -qq --no-install-recommends \
        "postgresql-${PG_VERSION}" "postgresql-client-${PG_VERSION}" \
        postgresql-contrib postgresql-client-common \
        smartmontools >/dev/null 2>&1 \
        || die "Fallo al instalar PostgreSQL. Revise apt y las fuentes configuradas."

    # Zabbix 7.x rechaza las versiones de TimescaleDB mas nuevas que 2.30
    # ("TimescaleDB version is too new"). Se instala la ultima de la serie 2.30,
    # compatible con 7.0, 7.4 y 8.0.
    # TimescaleDB se compone de dos paquetes: el 'loader' (que fija el
    # default_version de la extension) y la Community Edition (con los scripts
    # SQL). Deben instalarse con la MISMA version: si el loader va por delante,
    # la extension no encuentra su script de instalacion.
    local ts_pkg="timescaledb-2-postgresql-${PG_VERSION}"
    local ts_loader="timescaledb-2-loader-postgresql-${PG_VERSION}"
    local ts_ver=""
    local ts_max ts_series
    ts_max="$(zbx_max_ts_version "${ZBX_VERSION}")"
    ts_series="${ts_max%.*}"
    ts_ver="$(apt-cache madison "${ts_loader}" 2>/dev/null | awk '{print $3}' | grep -E "^${ts_series}\." | head -1 || true)"
    if [[ -z "${ts_ver}" ]]; then
        ts_ver="$(apt-cache madison "${ts_pkg}" 2>/dev/null | awk '{print $3}' | grep -E "^${ts_series}\." | head -1 || true)"
    fi
    if [[ -z "${ts_ver}" ]]; then
        ts_ver="$(apt-cache madison "${ts_loader}" 2>/dev/null | awk '{print $3}' | head -1 || true)"
    fi
    if [[ -n "${ts_ver}" ]]; then
        log_info_dim "Instalando TimescaleDB ${ts_ver} (compatible con Zabbix ${ZBX_VERSION})."
        apt-get install -y -qq --allow-downgrades \
            "${ts_loader}=${ts_ver}" "${ts_pkg}=${ts_ver}" >/dev/null 2>&1 \
            || die "No se pudo instalar TimescaleDB ${ts_ver}."
    else
        log_warn "No se encontro una version 2.30 de TimescaleDB; se instala la disponible."
        apt-get install -y -qq --no-install-recommends "${ts_pkg}" >/dev/null 2>&1 \
            || die "No se pudo instalar ${ts_pkg}."
    fi
    # La extension debe tener su script de instalacion disponible.
    local ts_ver_real
    ts_ver_real="$(dpkg-query -W -f='${Version}' "${ts_pkg}" 2>/dev/null | cut -d'~' -f1 || true)"
    if [[ -n "${ts_ver_real}" && ! -f "/usr/share/postgresql/${PG_VERSION}/extension/timescaledb--${ts_ver_real}.sql" ]]; then
        die "Falta el script de instalacion de la extension timescaledb ${ts_ver_real}."
    fi
    log_ok "PostgreSQL ${PG_VERSION} y TimescaleDB instalados."

    setup_postgres_cluster
    tune_postgresql
    setup_db_role_and_database
    configure_pg_hba

    # El esquema se importa con los scripts oficiales de Zabbix
    install_zabbix_repo "${ZBX_VERSION}"
    apt-get install -y -qq --no-install-recommends zabbix-sql-scripts >/dev/null 2>&1 \
        || die "No se pudo instalar zabbix-sql-scripts."
    install_db_schema

    open_port "${ZBX_DB_PORT}" tcp "${ZBX_SERVER_IP}"
    opt_systemd_limits
    systemctl restart "postgresql${PG_VERSION}-main" >/dev/null 2>&1 || true

    log_ok "Nodo de base de datos completado."
}

# ---------------------------------------------------------------------------
# NODO SERVIDOR ZABBIX
# ---------------------------------------------------------------------------

zabbix_server_tuning() {
    log_step "Ajustando parametros de rendimiento de zabbix-server"
    local conf="/etc/zabbix/zabbix_server.conf"
    [[ -f "${conf}" ]] || die "No se encuentra ${conf}."

    local pollers preprocessors discoverers http_pollers unreachable cache hist trend value hist_index
    pollers=$(( CPU_CORES * 5 ));   (( pollers < 5 ))    && pollers=5;    (( pollers > 50 ))   && pollers=50
    preprocessors=$(( CPU_CORES * 3 )); (( preprocessors < 3 )) && preprocessors=3; (( preprocessors > 30 )) && preprocessors=30
    discoverers=$(( CPU_CORES ));    (( discoverers < 1 )) && discoverers=1; (( discoverers > 10 )) && discoverers=10
    http_pollers=$(( CPU_CORES ));   (( http_pollers < 1 )) && http_pollers=1
    unreachable=$(( CPU_CORES ));    (( unreachable < 1 )) && unreachable=1

    cache=128; hist=64; trend=32; value=64; hist_index=16
    if (( RAM_MB >= 8192 )); then cache=512; hist=256; trend=128; value=256; hist_index=64
    elif (( RAM_MB >= 4096 )); then cache=256; hist=128; trend=64; value=128; hist_index=32
    fi

    set_conf "${conf}" "DBName"     "${ZBX_DB_NAME}"
    set_conf "${conf}" "DBUser"     "${ZBX_DB_USER}"
    set_conf "${conf}" "DBPassword" "${ZBX_DB_PASSWORD}"
    set_conf "${conf}" "DBHost"     "${ZBX_DB_HOST}"
    set_conf "${conf}" "DBPort"     "${ZBX_DB_PORT}"
    set_conf "${conf}" "ListenPort" "${ZBX_TRAPPER_PORT}"
    set_conf "${conf}" "LogType"    "file"
    set_conf "${conf}" "LogFile"    "/var/log/zabbix/zabbix_server.log"
    set_conf "${conf}" "PidFile"    "/run/zabbix/zabbix_server.pid"
    set_conf "${conf}" "SocketDir"  "/run/zabbix"

    set_conf "${conf}" "StartPollers"             "${pollers}"
    set_conf "${conf}" "StartPreprocessors"       "${preprocessors}"
    set_conf "${conf}" "StartDiscoverers"         "${discoverers}"
    set_conf "${conf}" "StartHTTPPollers"         "${http_pollers}"
    set_conf "${conf}" "StartPollersUnreachable"  "${unreachable}"
    set_conf "${conf}" "StartPingers"             "${unreachable}"
    set_conf "${conf}" "StartTrappers"            "5"
    set_conf "${conf}" "StartLLDProcessors"      "2"
    set_conf "${conf}" "CacheUpdateFrequency"     "60"
    set_conf "${conf}" "CacheSize"                "${cache}M"
    set_conf "${conf}" "HistoryCacheSize"         "${hist}M"
    set_conf "${conf}" "HistoryIndexCacheSize"    "${hist_index}M"
    set_conf "${conf}" "TrendCacheSize"           "${trend}M"
    set_conf "${conf}" "ValueCacheSize"           "${value}M"
    set_conf "${conf}" "Timeout"                  "30"
    set_conf "${conf}" "HousekeepingFrequency"    "1"
    set_conf "${conf}" "MaxHousekeeperDelete"     "10000"

    log_ok "Parametros ajustados (pollers=${pollers}, preprocessors=${preprocessors}, cache=${cache}M)."

    # Validacion de la configuracion: un parametro desconocido impide arrancar
    # el servicio, asi que se comprueba antes de reiniciarlo.
    if have_cmd zabbix_server; then
        # Algunos parametros cambian de nombre entre versiones (por ejemplo
        # StartLLDWorkers en 7.0 y StartLLDProcessors en 7.4). Si la version
        # instalada no reconoce alguno, se descarta y se vuelve a validar.
        local attempt bad verr
        for attempt in 1 2 3 4 5; do
            if zabbix_server -T -c "${conf}" >/dev/null 2>&1; then
                log_ok "Configuracion de zabbix-server validada."
                break
            fi
            bad="$(zabbix_server -T -c "${conf}" 2>&1 | grep -oE 'unknown parameter "[^"]+"' | head -1 | cut -d'"' -f2 || true)"
            if [[ -z "${bad}" ]]; then
                verr="$(zabbix_server -T -c "${conf}" 2>&1 || true)"
                log_warn "La configuracion de zabbix-server no supera la validacion:"
                while read -r line; do log_warn "  ${line}"; done <<<"${verr}"
                die "Configuracion invalida de zabbix_server."
            fi
            log_warn "El parametro ${bad} no existe en Zabbix ${ZBX_VERSION}; se omite."
            sed -i -E "/^[[:space:]]*${bad}=/d" "${conf}"
        done
    fi
}

configure_frontend() {
    log_step "Configurando el frontend (Zabbix + Nginx + PHP-FPM)"
    # El paquete zabbix-frontend-php deja el frontend en /usr/share/zabbix/ui y un
    # enlace simbolico ui/conf/zabbix.conf.php -> /etc/zabbix/web/zabbix.conf.php
    # (Zabbix 6.4+). En versiones anteriores el fichero vivia en /etc/zabbix.
    local conf=""
    if [[ -L /usr/share/zabbix/ui/conf/zabbix.conf.php ]]; then
        conf="$(readlink -f /usr/share/zabbix/ui/conf/zabbix.conf.php 2>/dev/null || true)"
    fi
    if [[ -z "${conf}" || ! -d "$(dirname "${conf}")" ]]; then
        if [[ -d /etc/zabbix/web ]]; then
            conf="/etc/zabbix/web/zabbix.conf.php"
        else
            conf="/etc/zabbix/zabbix.conf.php"
        fi
    fi
    log_info_dim "Configuracion del frontend: ${conf}"
    mkdir -p "$(dirname "${conf}")"
    cat >"${conf}" <<'PHP_EOF'
<?php
// Configuracion generada por zabbix-install.sh

$DB['TYPE']     = 'POSTGRESQL';
$DB['SERVER']   = '@@DB_HOST@@';
$DB['PORT']     = '@@DB_PORT@@';
$DB['DATABASE'] = '@@DB_NAME@@';
$DB['USER']     = '@@DB_USER@@';
$DB['PASSWORD'] = '@@DB_PASSWORD@@';

$DB['SCHEMA']      = 'public';
$DB['ENCRYPTION']  = false;
$DB['KEY_FILE']    = '';
$DB['CERT_FILE']   = '';
$DB['CA_FILE']     = '';
$DB['VERIFY_HOST'] = false;
$DB['CIPHER_LIST'] = '';

$ZBX_SERVER      = '@@SERVER_IP@@';
$ZBX_SERVER_PORT = '@@TRAPPER_PORT@@';
$ZBX_SERVER_NAME = '@@SERVER_NAME@@';

$IMAGE_FORMAT_DEFAULT = IMAGE_FORMAT_PNG;
PHP_EOF
    sed -i \
        -e "s|@@DB_HOST@@|${ZBX_DB_HOST}|g" \
        -e "s|@@DB_PORT@@|${ZBX_DB_PORT}|g" \
        -e "s|@@DB_NAME@@|${ZBX_DB_NAME}|g" \
        -e "s|@@DB_USER@@|${ZBX_DB_USER}|g" \
        -e "s|@@DB_PASSWORD@@|${ZBX_DB_PASSWORD}|g" \
        -e "s|@@SERVER_IP@@|${ZBX_SERVER_IP}|g" \
        -e "s|@@TRAPPER_PORT@@|${ZBX_TRAPPER_PORT}|g" \
        -e "s|@@SERVER_NAME@@|${ZBX_SERVER_NAME}|g" "${conf}"
    chmod 0640 "${conf}"

    chown root:www-data "${conf}" 2>/dev/null || true
    log_ok "Configuracion del frontend escrita en ${conf}."

    # --- Nginx ---
    local nginx_conf="/etc/zabbix/nginx.conf"
    [[ -f "${nginx_conf}" ]] || die "No se encuentra ${nginx_conf} (falta zabbix-nginx-conf)."

    # Version de PHP-FPM y socket efectivo
    local php_ver="" php_sock=""
    php_ver="$(ls -d /etc/php/*/fpm 2>/dev/null | awk -F/ '{print $4}' | sort -V | tail -n 1)"
    if [[ -n "${php_ver}" ]]; then
        php_sock="/run/php/php${php_ver}-fpm.sock"
    fi

    # El paquete Debian deja el vhost en /etc/zabbix/nginx.conf y tambien en
    # /etc/nginx/conf.d/zabbix.conf: hay que editar todas las copias activas.
    local -a vhosts=()
    local vf
    for vf in /etc/nginx/conf.d/zabbix.conf /etc/zabbix/nginx.conf; do
        [[ -f "${vf}" ]] && vhosts+=("${vf}")
    done

    local vh
    for vh in "${vhosts[@]}"; do
        sed -i -E "s@^[[:space:]]*#?[[:space:]]*listen[[:space:]]+[0-9]+;@listen ${ZBX_WEB_PORT};@" "${vh}"
        grep -qE "^[[:space:]]*listen[[:space:]]+${ZBX_WEB_PORT};" "${vh}" \
            || sed -i -E "s@^[[:space:]]*server_name.*@&\n    listen ${ZBX_WEB_PORT};@" "${vh}"
        sed -i -E "s@^[[:space:]]*#?[[:space:]]*server_name.*@server_name ${ZBX_SERVER_NAME};@" "${vh}"
        if [[ -n "${php_sock}" ]]; then
            sed -i -E "s@fastcgi_pass[[:space:]]+unix:[^;]+;@fastcgi_pass unix:${php_sock};@" "${vh}"
        fi
    done
    if [[ -n "${php_sock}" && -f /etc/zabbix/php-fpm.conf ]]; then
        sed -i -E "s@fastcgi_pass[[:space:]]+unix:[^;]+;@fastcgi_pass unix:${php_sock};@" /etc/zabbix/php-fpm.conf || true
    fi
    log_info_dim "Socket PHP-FPM configurado: ${php_sock:-detectado por el paquete}"

    # Publicar el vhost en Nginx si el paquete no lo hizo
    if [[ ! -f /etc/nginx/conf.d/zabbix.conf ]]; then
        cp "${nginx_conf}" /etc/nginx/conf.d/zabbix.conf
        log_info_dim "Vhost de Zabbix publicado en /etc/nginx/conf.d/zabbix.conf."
    fi
    if [[ "${ZBX_WEB_PORT}" == "80" ]] && [[ -f /etc/nginx/sites-enabled/default ]]; then
        rm -f /etc/nginx/sites-enabled/default
        log_info_dim "Sitio por defecto de Nginx deshabilitado (se usa el puerto 80 para Zabbix)."
    fi
    nginx -t >/dev/null 2>&1 || log_warn "nginx -t devuelve error; revise /etc/nginx/conf.d/zabbix.conf."

    log_ok "Frontend configurado en el puerto ${ZBX_WEB_PORT}."
}

configure_agent() {
    log_step "Configurando zabbix-agent2"
    local conf="/etc/zabbix/zabbix_agent2.conf"
    [[ -f "${conf}" ]] || die "No se encuentra ${conf}."
    # El agente del propio nodo servidor se comunica con el Zabbix server local.
    set_conf "${conf}" "Server"        "127.0.0.1"
    set_conf "${conf}" "ServerActive"  "${ZBX_SERVER_IP}"
    set_conf "${conf}" "Hostname"      "${ZBX_HOSTNAME}"
    set_conf "${conf}" "LogType"       "file"
    set_conf "${conf}" "LogFile"       "/var/log/zabbix/zabbix_agent2.log"
    set_conf "${conf}" "Timeout"       "30"
    log_ok "Agente configurado con Server=${ZBX_SERVER_IP}."
}

tune_php() {
    local php_ver
    php_ver="$(ls -d /etc/php/*/fpm 2>/dev/null | awk -F/ '{print $4}' | sort -V | tail -n 1)"
    [[ -n "${php_ver}" ]] || return 0
    local fpmdir="/etc/php/${php_ver}/fpm"
    local max_children=$(( RAM_MB / 128 )); (( max_children < 10 )) && max_children=10; (( max_children > 60 )) && max_children=60

    cat >"${fpmdir}/conf.d/99-zabbix-tuning.ini" <<PHPINI_EOF
; Ajustes generados por zabbix-install.sh
memory_limit = 256M
upload_max_filesize = 16M
post_max_size = 16M
max_execution_time = 300
max_input_vars = 10000
date.timezone = ${ZBX_TIMEZONE}
opcache.enable = 1
opcache.memory_consumption = 128
opcache.interned_strings_buffer = 16
opcache.max_accelerated_files = 10000
opcache.revalidate_freq = 60
opcache.validate_timestamps = 1
PHPINI_EOF

    local pool="${fpmdir}/pool.d/www.conf"
    if [[ -f "${pool}" ]]; then
        sed -i -E "s@^;?[[:space:]]*pm\.max_children[[:space:]]*=.*@pm.max_children = ${max_children}@" "${pool}"
        sed -i -E "s@^;?[[:space:]]*pm\.start_servers[[:space:]]*=.*@pm.start_servers = 2@" "${pool}"
        sed -i -E "s@^;?[[:space:]]*pm\.min_spare_servers[[:space:]]*=.*@pm.min_spare_servers = 2@" "${pool}"
        sed -i -E "s@^;?[[:space:]]*pm\.max_spare_servers[[:space:]]*=.*@pm.max_spare_servers = 8@" "${pool}"
        sed -i -E "s@^;?[[:space:]]*pm\.process_idle_timeout[[:space:]]*=.*@pm.process_idle_timeout = 30s@" "${pool}"
        systemctl restart "php${php_ver}-fpm" >/dev/null 2>&1 || true
    fi
    log_ok "PHP ${php_ver} optimizado (pm.max_children=${max_children})."
}

install_server_node() {
    section "NODO SERVIDOR ZABBIX - server + frontend + agent2"
    install_base_packages
    set_timezone
    opt_sysctl
    opt_disable_junk

    install_zabbix_repo "${ZBX_VERSION}"
    log_step "Instalando los componentes de Zabbix ${ZBX_VERSION}"
    apt-get install -y -qq --no-install-recommends \
        zabbix-server-pgsql zabbix-frontend-php zabbix-nginx-conf \
        zabbix-agent2 zabbix-agent2-plugin-postgresql zabbix-sql-scripts \
        "postgresql-client-${PG_VERSION}" \
        smartmontools nginx >/dev/null 2>&1 \
        || die "Fallo al instalar los componentes de Zabbix ${ZBX_VERSION}."

    # PHP-FPM y extensiones exigidas por el frontend (Debian 13 = PHP 8.4)
    local php_pkg_ver
    php_pkg_ver="$(apt-cache search --names-only '^php[0-9.]+-fpm$' | awk -F- '{print $1}' | sort -V | tail -n 1)"
    if [[ -n "${php_pkg_ver}" ]]; then
        apt-get install -y -qq --no-install-recommends \
            "${php_pkg_ver}-fpm" "${php_pkg_ver}-pgsql" "${php_pkg_ver}-bcmath" \
            "${php_pkg_ver}-mbstring" "${php_pkg_ver}-gd" "${php_pkg_ver}-curl" \
            "${php_pkg_ver}-xml" >/dev/null 2>&1 \
            || log_warn "Fallo al instalar PHP ${php_pkg_ver}; se intentaran los metapaquetes."
    fi
    if ! have_cmd php-fpm; then
        apt-get install -y -qq --no-install-recommends \
            php-fpm php-pgsql php-bcmath php-mbstring php-gd php-curl php-xml >/dev/null 2>&1 \
            || die "No se pudo instalar PHP-FPM con las extensiones requeridas por el frontend."
    fi
    log_ok "Componentes de Zabbix ${ZBX_VERSION} instalados."

    zabbix_server_tuning
    configure_frontend
    configure_agent
    tune_php

    log_step "Comprobando conectividad con la base de datos"
    local db_ready=0 db_try
    for db_try in $(seq 1 15); do
        if PGPASSWORD="${ZBX_DB_PASSWORD}" pg_isready -h "${ZBX_DB_HOST}" -p "${ZBX_DB_PORT}" -U "${ZBX_DB_USER}" >/dev/null 2>&1; then
            db_ready=1; break
        fi
        sleep 2
    done
    if [[ "${db_ready}" == "1" ]]; then
        log_ok "Base de datos accesible en ${ZBX_DB_HOST}:${ZBX_DB_PORT}."
    else
        log_warn "No se pudo confirmar la conexion con ${ZBX_DB_HOST}:${ZBX_DB_PORT}."
        log_warn "Verifique que el nodo de base de datos esta instalado y que pg_hba.conf permite ${ZBX_SERVER_IP}."
    fi

    log_step "Habilitando y arrancando servicios"
    systemctl enable zabbix-server zabbix-agent2 nginx >/dev/null 2>&1 || true
    local php_ver
    php_ver="$(ls -d /etc/php/*/fpm 2>/dev/null | awk -F/ '{print $4}' | sort -V | tail -n 1)"
    [[ -n "${php_ver}" ]] && systemctl enable "php${php_ver}-fpm" >/dev/null 2>&1 || true
    systemctl restart zabbix-agent2 >/dev/null 2>&1 || true
    systemctl restart zabbix-server >/dev/null 2>&1 || true
    systemctl restart nginx >/dev/null 2>&1 || true
    opt_systemd_limits

    # El servidor puede arrancar antes de que la base de datos termine de
    # importar el esquema: se reintenta hasta que quede activo.
    local srv_try srv_state="" jlog
    for srv_try in $(seq 1 20); do
        srv_state="$(systemctl is-active zabbix-server 2>/dev/null || true)"
        if [[ "${srv_state}" == "active" ]]; then
            break
        fi
        sleep 10
        systemctl restart zabbix-server >/dev/null 2>&1 || true
    done
    if [[ "${srv_state}" != "active" ]]; then
        jlog="$(journalctl -u zabbix-server --no-pager -n 12 2>/dev/null || true)"
        log_error "El servicio zabbix-server no queda activo. Ultimas lineas del journal:"
        while read -r line; do log_warn "  ${line}"; done <<<"${jlog}"
        if grep -qi "timescaledb version is too new" <<<"${jlog}"; then
            die "La version de TimescaleDB instalada es demasiado nueva para Zabbix ${ZBX_VERSION}. Instale una version 2.30.x de timescaledb-2-postgresql-${PG_VERSION}."
        fi
        die "El servicio zabbix-server no arranca. Revise journalctl -u zabbix-server."
    fi
    log_ok "Servicio zabbix-server activo."

    # Comprobacion funcional del frontend ( Nginx y PHP-FPM ya estan arrancados).
    local ftry fcode=""
    for ftry in $(seq 1 15); do
        fcode="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:${ZBX_WEB_PORT}/" 2>/dev/null || true)"
        case "${fcode}" in
            200|302) break ;;
        esac
        sleep 2
    done
    case "${fcode}" in
        200|302) log_ok "Frontend respondiendo en el puerto ${ZBX_WEB_PORT} (HTTP ${fcode})." ;;
        *)
            log_warn "El frontend no responde en http://127.0.0.1:${ZBX_WEB_PORT}/ (codigo ${fcode:-sin respuesta})."
            log_warn "Revise la configuracion del frontend y el vhost de Nginx."
            die "El frontend no responde tras la instalacion."
            ;;
    esac

    open_port "${ZBX_WEB_PORT}" tcp any
    open_port "${ZBX_TRAPPER_PORT}" tcp any
    open_port "${ZBX_AGENT_PORT}" tcp any

    log_ok "Nodo servidor Zabbix completado."
}

# Habilita TimescaleDB (hypertables + compresion) sobre el stack ya desplegado.
# Es una mejora opcional: si algo falla, el stack sigue funcionando con PostgreSQL.
enable_timescaledb_docker() {
    log_step "Habilitando TimescaleDB (hypertables y compresion)"

    # El contenedor del servidor crea el esquema de Zabbix al arrancar. Se
    # espera a que la base este completa: si no, la conversion a hypertables
    # se aplica sobre un esquema a medias y no surte efecto.
    local wtry ready=0 probe=""
    for wtry in $(seq 1 60); do
        probe="$(dc exec -i zabbix-db psql -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" -tAc \
            "SELECT count(*) FROM pg_tables WHERE schemaname='public' AND tablename='users'" 2>/dev/null || true)"
        if grep -q "1" <<<"${probe}"; then
            ready=1
            break
        fi
        sleep 5
    done
    if [[ "${ready}" != "1" ]]; then
        log_warn "El esquema de Zabbix no termino de importarse; se omite la conversion a hypertables."
        return 0
    fi

    dc exec -i zabbix-db psql -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" \
        -c "CREATE EXTENSION IF NOT EXISTS timescaledb CASCADE;" >/dev/null 2>&1 \
        || { log_warn "No se pudo crear la extension timescaledb; se continua sin hypertables."; return 0; }

    local schema
    schema="$(dc exec -i zabbix-server sh -c 'cat /usr/share/doc/zabbix-server-postgresql/postgresql/timescaledb.sql 2>/dev/null || cat /usr/share/doc/zabbix-server-postgresql/timescaledb/schema.sql 2>/dev/null || cat /usr/share/zabbix/sql-scripts/postgresql/timescaledb/schema.sql 2>/dev/null || cat /usr/share/doc/zabbix-sql-scripts/postgresql/timescaledb/schema.sql 2>/dev/null' 2>/dev/null || true)"
    if [[ -z "${schema}" ]]; then
        log_warn "No se localizo el script de hypertables en la imagen; se continua sin conversion."
        return 0
    fi

    # La migracion requiere el servidor detenido
    dc stop zabbix-server zabbix-web >/dev/null 2>&1 || true
    if printf '%s' "${schema}" | dc exec -i zabbix-db psql -q -v ON_ERROR_STOP=1 \
            -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" >/dev/null 2>&1; then
        local hcount
        hcount="$(dc exec -i zabbix-db psql -U "${ZBX_DB_USER}" -d "${ZBX_DB_NAME}" -tAc \
            "SELECT count(*) FROM timescaledb_information.hypertables WHERE hypertable_schema='public'" 2>/dev/null || true)"
        hcount="$(tr -dc '0-9' <<<"${hcount:-0}")"
        log_ok "Hypertables creadas (${hcount:-0}) y compresion habilitada."
    else
        log_warn "La conversion a hypertables no se completo correctamente."
    fi
    dc start zabbix-server zabbix-web >/dev/null 2>&1 || true
}

# ---------------------------------------------------------------------------
# INSTALACION CONTENORIZADA (Docker)
# ---------------------------------------------------------------------------

install_docker() {
    log_step "Fase 1: instalando Docker y Docker Compose"
    if have_cmd docker && docker compose version >/dev/null 2>&1; then
        log_ok "Docker y el plugin Compose ya estan instalados."
    else
        log_info "Ejecutando el instalador oficial desatendido de Docker..."
        curl -fsSL --retry 3 --connect-timeout 30 https://get.docker.com -o /tmp/get-docker.sh \
            || die "No se pudo descargar https://get.docker.com"
        sh /tmp/get-docker.sh >/tmp/docker-install.log 2>&1 \
            || die "El instalador de Docker fallo. Revise /tmp/docker-install.log"
        rm -f /tmp/get-docker.sh
        log_ok "Docker instalado."
    fi
    systemctl enable --now docker >/dev/null 2>&1 || log_warn "No se pudo habilitar el servicio docker."
    if ! docker compose version >/dev/null 2>&1; then
        log_warn "El plugin docker compose no esta disponible; se intentara instalarlo desde apt."
        apt-get install -y -qq docker-compose-plugin >/dev/null 2>&1 \
            || die "No se pudo instalar docker-compose-plugin."
    fi
    docker compose version >/dev/null 2>&1 || die "Docker Compose v2 no esta disponible."
    log_ok "Docker Compose disponible."
}

write_docker_env() {
    local envfile="${ZBX_DOCKER_DIR}/.env"
    umask 077
    cat >"${envfile}" <<ENV_EOF
# Generado por zabbix-install.sh - credenciales del stack Zabbix
POSTGRES_USER=${ZBX_DB_USER}
POSTGRES_PASSWORD=${ZBX_DB_PASSWORD}
POSTGRES_DB=${ZBX_DB_NAME}
ZABBIX_VERSION=${ZBX_VERSION}
ZBX_WEB_PORT=${ZBX_WEB_PORT}
PHP_TZ=${ZBX_TIMEZONE}
ZBX_SERVER_NAME=${ZBX_SERVER_NAME}
ENV_EOF
    chmod 0600 "${envfile}"
    log_ok "Credenciales guardadas en ${envfile} (permisos 600)."
}

generate_compose() {
    local compose="${ZBX_DOCKER_DIR}/docker-compose.yml"
    mkdir -p "${ZBX_DOCKER_DIR}" || die "No se pudo crear el directorio ${ZBX_DOCKER_DIR}"
    local tag="alpine-${ZBX_VERSION}-latest"
    local ts_image
    ts_image="$(ts_image_tag "${ZBX_VERSION}")"

    local pollers preprocessors discoverers cache hist trend value
    pollers=$(( CPU_CORES * 5 ));   (( pollers < 5 ))  && pollers=5;  (( pollers > 50 )) && pollers=50
    preprocessors=$(( CPU_CORES * 3 )); (( preprocessors < 3 )) && preprocessors=3; (( preprocessors > 30 )) && preprocessors=30
    discoverers=$(( CPU_CORES ));    (( discoverers < 1 )) && discoverers=1
    cache=128; hist=64; trend=32; value=64
    if (( RAM_MB >= 8192 )); then cache=512; hist=256; trend=128; value=256
    elif (( RAM_MB >= 4096 )); then cache=256; hist=128; trend=64; value=128
    fi

    log_step "Fase 2: generando ${compose}"
    cat >"${compose}" <<COMPOSE_EOF
# Generado por zabbix-install.sh (Zabbix ${ZBX_VERSION})
# Levantar:   docker compose up -d
# Ver logs:    docker compose logs -f
# Detener:     docker compose down

services:
  zabbix-db:
    image: ${ts_image}
    container_name: zabbix-db
    restart: unless-stopped
    shm_size: 1gb
    environment:
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      TIMESCALEDB_TELEMETRY: "off"
    command:
      - postgres
      - -c
      - shared_buffers=$(( RAM_MB / 4 ))MB
      - -c
      - effective_cache_size=$(( RAM_MB / 2 ))MB
      - -c
      - work_mem=64MB
      - -c
      - maintenance_work_mem=256MB
      - -c
      - max_connections=200
      - -c
      - max_wal_size=2GB
      - -c
      - min_wal_size=512MB
      - -c
      - checkpoint_timeout=15min
      - -c
      - random_page_cost=1.1
      - -c
      - wal_compression=on
      - -c
      - timezone=${ZBX_TIMEZONE}
    volumes:
      - zabbix-db-data:/var/lib/postgresql/data
    healthcheck:
      test: ["CMD-SHELL", "pg_isready -U \${POSTGRES_USER} -d \${POSTGRES_DB}"]
      interval: 10s
      timeout: 5s
      retries: 12
      start_period: 30s
    networks:
      - zabbix-net

  zabbix-server:
    image: zabbix/zabbix-server-pgsql:${tag}
    container_name: zabbix-server
    restart: unless-stopped
    depends_on:
      zabbix-db:
        condition: service_healthy
    environment:
      DB_SERVER_HOST: zabbix-db
      DB_SERVER_PORT: "5432"
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      ZBX_STARTPOLLERS: "${pollers}"
      ZBX_STARTPREPROCESSORS: "${preprocessors}"
      ZBX_STARTDISCOVERERS: "${discoverers}"
      ZBX_STARTTRAPPERS: "5"
      ZBX_CACHESIZE: "${cache}M"
      ZBX_HISTORYCACHESIZE: "${hist}M"
      ZBX_TRENDCACHESIZE: "${trend}M"
      ZBX_VALUECACHESIZE: "${value}M"
    ports:
      - "${ZBX_TRAPPER_PORT}:10051"
    volumes:
      - zabbix-server-data:/var/lib/zabbix
      - ./zabbix/alertscripts:/usr/lib/zabbix/alertscripts:ro
      - ./zabbix/externalscripts:/usr/lib/zabbix/externalscripts:ro
      - ./zabbix/snmptraps:/var/lib/zabbix/snmptraps
      - ./zabbix/export:/var/lib/zabbix/export
    ulimits:
      nofile:
        soft: 65536
        hard: 65536
      nproc:
        soft: 65536
        hard: 65536
    healthcheck:
      test: ["CMD-SHELL", "pgrep zabbix_server > /dev/null || exit 1"]
      interval: 30s
      timeout: 15s
      retries: 5
      start_period: 60s
    networks:
      - zabbix-net

  zabbix-web:
    image: zabbix/zabbix-web-nginx-pgsql:${tag}
    container_name: zabbix-web
    restart: unless-stopped
    depends_on:
      zabbix-db:
        condition: service_healthy
      zabbix-server:
        condition: service_started
    environment:
      ZBX_SERVER_HOST: zabbix-server
      DB_SERVER_HOST: zabbix-db
      DB_SERVER_PORT: "5432"
      POSTGRES_USER: \${POSTGRES_USER}
      POSTGRES_PASSWORD: \${POSTGRES_PASSWORD}
      POSTGRES_DB: \${POSTGRES_DB}
      PHP_TZ: "${ZBX_TIMEZONE}"
    ports:
      - "${ZBX_WEB_PORT}:8080"
    volumes:
      - ./zabbix/certs:/etc/ssl/nginx:ro
    healthcheck:
      test: ["CMD-SHELL", "wget -q -O /dev/null http://localhost:8080/ || exit 1"]
      interval: 30s
      timeout: 10s
      retries: 5
      start_period: 30s
    networks:
      - zabbix-net

volumes:
  zabbix-db-data:
  zabbix-server-data:

networks:
  zabbix-net:
    driver: bridge
COMPOSE_EOF
    log_ok "docker-compose.yml generado en ${compose}."
}

prepare_docker_dirs() {
    log_step "Preparando directorios de datos y scripts"
    mkdir -p "${ZBX_DOCKER_DIR}/zabbix/alertscripts" \
             "${ZBX_DOCKER_DIR}/zabbix/externalscripts" \
             "${ZBX_DOCKER_DIR}/zabbix/snmptraps" \
             "${ZBX_DOCKER_DIR}/zabbix/export" \
             "${ZBX_DOCKER_DIR}/zabbix/nginx" \
             "${ZBX_DOCKER_DIR}/zabbix/certs"
    chmod 0755 "${ZBX_DOCKER_DIR}/zabbix/alertscripts" "${ZBX_DOCKER_DIR}/zabbix/externalscripts"
    chmod 0775 "${ZBX_DOCKER_DIR}/zabbix/snmptraps" "${ZBX_DOCKER_DIR}/zabbix/export"
    log_ok "Directorios preparados."
}

# dc: ejecutor de docker compose apuntando siempre al directorio del stack
dc() {
    docker compose --project-directory "${ZBX_DOCKER_DIR}" \
        -f "${ZBX_DOCKER_DIR}/docker-compose.yml" \
        --env-file "${ZBX_DOCKER_DIR}/.env" "$@"
}

deploy_docker_stack() {
    log_step "Fase 3: levantando el stack"
    [[ -f "${ZBX_DOCKER_DIR}/docker-compose.yml" ]] || die "No se encuentra el docker-compose.yml"
    dc pull >/dev/null 2>&1 || log_warn "No se pudieron descargar todas las imagenes; se continuara."
    dc up -d || die "Fallo al levantar el stack con docker compose."
    log_ok "Stack levantado:"
    dc ps
}

verify_docker_stack() {
    log_step "Verificando el stack"
    local i db_ok=0 web_ok=0
    for i in $(seq 1 60); do
        if [[ "$(docker inspect --format '{{.State.Health.Status}}' zabbix-db 2>/dev/null)" == "healthy" ]]; then db_ok=1; fi
        if [[ "$(docker inspect --format '{{.State.Health.Status}}' zabbix-web 2>/dev/null)" == "healthy" ]]; then web_ok=1; fi
        if [[ "${db_ok}" == "1" && "${web_ok}" == "1" ]]; then break; fi
        sleep 5
    done
    if [[ "${db_ok}" == "1" ]]; then
        log_ok "Base de datos saludable."
    else
        log_warn "La base de datos no ha alcanzado el estado healthy. Revise: docker compose logs zabbix-db"
    fi
    if [[ "${web_ok}" == "1" ]]; then
        log_ok "Frontend saludable."
    else
        log_warn "El frontend no ha alcanzado el estado healthy. Revise: docker compose logs zabbix-web"
    fi
}

docker_installation() {
    section "INSTALACION CONTENORIZADA - Docker + Docker Compose"
    install_docker

    ask_menu "Seleccione la version de Zabbix" "Zabbix 7.0 (LTS)" "Zabbix 7.4" "Zabbix 8.0 (LTS)"
    case "${CHOICE}" in
        1) ZBX_VERSION="7.0" ;;
        2) ZBX_VERSION="7.4" ;;
        3) ZBX_VERSION="8.0" ;;
    esac

    ask "Zona horaria" "${ZBX_TIMEZONE}"
    ZBX_TIMEZONE="${ANSWER}"

    ask "Puerto del frontend web en el host" "${ZBX_WEB_PORT}"
    ZBX_WEB_PORT="${ANSWER}"

    ask "Nombre del servidor Zabbix (para la interfaz web)" "zabbix-server"
    ZBX_SERVER_NAME="${ANSWER}"

    ask "Usuario de la base de datos" "${ZBX_DB_USER}"
    ZBX_DB_USER="${ANSWER}"
    [[ "${ZBX_DB_USER}" =~ ^[A-Za-z_][A-Za-z0-9_]{0,62}$ ]] || die "Usuario de base de datos no valido."

    ask_password "Contrasena de la base de datos"
    ZBX_DB_PASSWORD="${ANSWER}"

    ask "Directorio donde crear el stack" "${ZBX_DOCKER_DIR}"
    ZBX_DOCKER_DIR="${ANSWER}"
    mkdir -p "${ZBX_DOCKER_DIR}" || die "No se pudo crear ${ZBX_DOCKER_DIR}"

    prepare_docker_dirs
    write_docker_env
    generate_compose
    deploy_docker_stack
    enable_timescaledb_docker
    verify_docker_stack

    section "INSTALACION CONTENORIZADA COMPLETADA"
    cat <<EOF
Zabbix ${ZBX_VERSION} desplegado con Docker.

  Frontend web : http://<IP-del-host>:${ZBX_WEB_PORT}
  Agentes      : <IP-del-host>:${ZBX_TRAPPER_PORT}
  Credenciales de BD: usuario ${ZBX_DB_USER} en ${ZBX_DOCKER_DIR}/.env
  Credenciales Zabbix: Admin / zabbix

  Config nginx extra: ${ZBX_DOCKER_DIR}/zabbix/nginx (copie dentro del contenedor)

  Comandos utiles:
    cd ${ZBX_DOCKER_DIR}
    docker compose ps
    docker compose logs -f zabbix-server
    docker compose down
EOF
}

# ---------------------------------------------------------------------------
# INSTALACION NATIVA DISTRIBUIDA
# ---------------------------------------------------------------------------

native_installation() {
    section "INSTALACION NATIVA DISTRIBUIDA - Debian 13 (Trixie)"
    check_os
    detect_hardware

    ask_menu "Seleccione el rol de este nodo" \
        "Nodo Servidor Zabbix (server + frontend + agent2)" \
        "Nodo Base de Datos (PostgreSQL + TimescaleDB)"
    local role="${CHOICE}"

    ask_menu "Seleccione la version de Zabbix" \
        "Zabbix 7.0 (LTS)" \
        "Zabbix 7.4" \
        "Zabbix 8.0 (LTS)"
    case "${CHOICE}" in
        1) ZBX_VERSION="7.0" ;;
        2) ZBX_VERSION="7.4" ;;
        3) ZBX_VERSION="8.0" ;;
    esac

    ask "Zona horaria" "${ZBX_TIMEZONE}"
    ZBX_TIMEZONE="${ANSWER}"

    if [[ "${role}" == "1" ]]; then
        ask_ipv4 "IP del nodo SERVIDOR Zabbix (este nodo)" "$(detect_local_ip)"
        ZBX_SERVER_IP="${ANSWER}"

        ask_ipv4 "IP del nodo BASE DE DATOS"
        ZBX_DB_HOST="${ANSWER}"

        ask "Puerto de PostgreSQL en el nodo de base de datos" "${ZBX_DB_PORT}"
        ZBX_DB_PORT="${ANSWER}"

        ask "Nombre de la base de datos" "${ZBX_DB_NAME}"
        ZBX_DB_NAME="${ANSWER}"

        ask "Usuario de la base de datos" "${ZBX_DB_USER}"
        ZBX_DB_USER="${ANSWER}"

        ask_password "Contrasena de la base de datos"
        ZBX_DB_PASSWORD="${ANSWER}"

        ask "Puerto del frontend web" "${ZBX_WEB_PORT}"
        ZBX_WEB_PORT="${ANSWER}"

        ask "Nombre del servidor Zabbix" "zabbix-server"
        ZBX_SERVER_NAME="${ANSWER}"

        ask "Hostname visible del agente" "$(hostname -s 2>/dev/null || echo zabbix-server)"
        ZBX_HOSTNAME="${ANSWER}"

        section "RESUMEN - NODO SERVIDOR ZABBIX ${ZBX_VERSION}"
        cat <<EOF
  Rol                 : Servidor Zabbix (server + frontend + agent2)
  IP del servidor     : ${ZBX_SERVER_IP}
  IP de la base datos : ${ZBX_DB_HOST}:${ZBX_DB_PORT}
  Base de datos       : ${ZBX_DB_NAME} (usuario ${ZBX_DB_USER})
  Puerto del frontend : ${ZBX_WEB_PORT}
  Zona horaria        : ${ZBX_TIMEZONE}
  Hostname del agente : ${ZBX_HOSTNAME}
EOF
        confirm "Confirmar la instalacion en el nodo servidor?" || die "Instalacion cancelada."
        install_server_node

        section "NODO SERVIDOR ZABBIX COMPLETADO"
        cat <<EOF
Zabbix ${ZBX_VERSION} instalado en el nodo servidor.

  Frontend web : http://${ZBX_SERVER_IP}:${ZBX_WEB_PORT}
  Credenciales Zabbix por defecto: Admin / zabbix

  Siguiente paso: ejecutar este script en el nodo de base de datos
  con la opcion 2 (Nodo Base de Datos) y la misma contrasena.
EOF
    else
        ask_ipv4 "IP del nodo BASE DE DATOS (este nodo)" "$(detect_local_ip)"
        ZBX_DB_HOST="${ANSWER}"

        ask_ipv4 "IP del nodo SERVIDOR Zabbix (unico origen permitido)"
        ZBX_SERVER_IP="${ANSWER}"

        ask "Puerto de PostgreSQL" "${ZBX_DB_PORT}"
        ZBX_DB_PORT="${ANSWER}"

        ask "Nombre de la base de datos" "${ZBX_DB_NAME}"
        ZBX_DB_NAME="${ANSWER}"

        ask "Usuario de la base de datos" "${ZBX_DB_USER}"
        ZBX_DB_USER="${ANSWER}"

        ask_password "Contrasena de la base de datos"
        ZBX_DB_PASSWORD="${ANSWER}"

        section "RESUMEN - NODO BASE DE DATOS"
        cat <<EOF
  Rol                 : Base de datos (PostgreSQL ${PG_VERSION} + TimescaleDB)
  IP de la base datos : ${ZBX_DB_HOST}:${ZBX_DB_PORT}
  IP del servidor     : ${ZBX_SERVER_IP} (unico origen permitido)
  Base de datos       : ${ZBX_DB_NAME} (usuario ${ZBX_DB_USER})
  Zona horaria        : ${ZBX_TIMEZONE}
EOF
        confirm "Confirmar la instalacion en el nodo de base de datos?" || die "Instalacion cancelada."
        install_db_node

        section "NODO BASE DE DATOS COMPLETADO"
        cat <<EOF
PostgreSQL ${PG_VERSION} + TimescaleDB instalados y esquema de Zabbix importado.

  Puerto      : ${ZBX_DB_PORT}
  Base        : ${ZBX_DB_NAME}
  Usuario     : ${ZBX_DB_USER}
  Acceso desde: ${ZBX_SERVER_IP} unicamente

  Siguiente paso: ejecutar este script en el nodo servidor
  con la opcion 1 (Nodo Servidor Zabbix) y la misma contrasena.
EOF
    fi
}

# ---------------------------------------------------------------------------
# Menu principal
# ---------------------------------------------------------------------------

show_banner() {
    printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "############################################################" "${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "#     Instalador de Zabbix para despliegues en clientes       #" "${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "#                    version ${SCRIPT_VERSION}                         #" "${C_RESET}"
    printf '%s%s%s\n' "${C_BOLD}${C_CYAN}" "############################################################" "${C_RESET}"
}

main() {
    show_banner
    require_root
    detect_hardware

    while true; do
        ask_menu "Seleccione el tipo de instalacion" \
            "Instalacion nativa distribuida (Debian 13, 2 nodos)" \
            "Instalacion contenizada (Docker + Docker Compose)" \
            "Salir"
        case "${CHOICE}" in
            1) native_installation; log_info "Instalacion nativa completada. Saliendo."; exit 0 ;;
            2) docker_installation; log_info "Instalacion contenizada completada. Saliendo."; exit 0 ;;
            3) log_info "Saliendo."; exit 0 ;;
        esac
    done
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
