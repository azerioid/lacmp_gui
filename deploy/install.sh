#!/usr/bin/env bash
# LACMP Panel installer — the only place that contains real install logic.
# Invoked by ./lacmp_gui.sh (documented) or directly by advanced users.
#
# Idempotent: re-running updates code without rotating DB passwords,
# APP_KEY, or broker.json unless --reset-db is passed.
set -euo pipefail

if [[ ${EUID} -ne 0 && "${1:-}" != "-h" && "${1:-}" != "--help" ]]; then
    echo "install.sh must run as root" >&2
    exit 1
fi

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PREFIX="${PREFIX:-/usr/local/lib/lacmp-panel}"
WWW_ROOT="${WWW_ROOT:-/data/www}"
CADDY_CONFD="${CADDY_CONFD:-/etc/caddy/conf.d}"
CADDYFILE='/etc/caddy/Caddyfile'
WEB_USER="${WEB_USER:-}"
PHP_VER="${PHP_VER:-}"
RESET_DB=0
INSTALL_CADDY_SNIPPET=1
ACCESS="${ACCESS:-}"
PANEL_DOMAIN="${PANEL_DOMAIN:-}"
PANEL_IP="${PANEL_IP:-}"
DEFAULT_PANEL_PORT=3169
PANEL_PORT="${PANEL_PORT:-$DEFAULT_PANEL_PORT}"
PORT_FROM_CLI=0
PREV_PORTS=""
PREV_ALLOW_IPS=""
STACK="${STACK:-auto}"
WEB_SERVICE=""
VHOST_DIR=""
VHOST_AVAILABLE=""
VHOST_FORMAT=""
APACHE_CTL=""
WEB_LOG_DIR=""
LE_EMAIL="${LE_EMAIL:-}"
ENABLE_UFW=0
SKIP_CADDY=0
ALLOW_IPS=()
EXTRA_READONLY=()
CADDY_RELOAD="${CADDY_RELOAD:-auto}"
REQUIRE_TOTP="${REQUIRE_TOTP:-}"
DO_FIREWALL="${DO_FIREWALL:-}"
DO_FAIL2BAN="${DO_FAIL2BAN:-}"
NON_INTERACTIVE=0
DRY_RUN=0

detect_stack() {
    STACK="$(echo "${STACK}" | tr '[:upper:]' '[:lower:]')"
    case "${STACK}" in
        auto|lacmp|lamp) ;;
        *) echo "Invalid --stack=${STACK} (use auto|lacmp|lamp)" >&2; exit 2 ;;
    esac
    local has_lacmp=0 has_lamp=0
    command -v lacmp >/dev/null 2>&1 && has_lacmp=1
    command -v lamp >/dev/null 2>&1 && has_lamp=1
    if [[ "${STACK}" == "auto" ]]; then
        local listener=""
        listener="$(ss -tlnp 2>/dev/null | awk '$4 ~ /:80$/ {print; exit}' || true)"
        if echo "${listener}" | grep -qi caddy; then
            STACK=lacmp
        elif echo "${listener}" | grep -qiE 'apache|httpd'; then
            STACK=lamp
        elif [[ "${has_lacmp}" -eq 1 && "${has_lamp}" -eq 0 ]]; then
            STACK=lacmp
        elif [[ "${has_lamp}" -eq 1 && "${has_lacmp}" -eq 0 ]]; then
            STACK=lamp
        elif [[ "${has_lacmp}" -eq 1 ]]; then
            STACK=lacmp
        elif [[ "${has_lamp}" -eq 1 ]]; then
            STACK=lamp
        else
            echo "Neither LACMP nor LAMP was detected. Install teddysun/lacmp or teddysun/lamp first." >&2
            exit 1
        fi
    fi
    if [[ "${STACK}" == "lacmp" && "${has_lacmp}" -eq 0 ]]; then
        echo "--stack=lacmp requires the 'lacmp' command (teddysun/lacmp)." >&2
        exit 1
    fi
    if [[ "${STACK}" == "lamp" && "${has_lamp}" -eq 0 ]]; then
        echo "--stack=lamp requires the 'lamp' command (teddysun/lamp)." >&2
        exit 1
    fi
    if [[ "${STACK}" == "lacmp" ]]; then
        WEB_SERVICE=caddy
        VHOST_DIR="${CADDY_CONFD}"
        VHOST_AVAILABLE=""
        VHOST_FORMAT=caddyfile
        WEB_LOG_DIR=/var/log/caddy
        CADDY_BIN="$(command -v caddy || echo /usr/bin/caddy)"
    else
        if [[ -d /etc/apache2/sites-available ]]; then
            WEB_SERVICE=apache2
            VHOST_DIR=/etc/apache2/sites-enabled
            VHOST_AVAILABLE=/etc/apache2/sites-available
            WEB_LOG_DIR=/var/log/apache2
            APACHE_CTL="$(command -v apache2ctl || command -v apachectl || echo /usr/sbin/apache2ctl)"
        else
            WEB_SERVICE=httpd
            VHOST_DIR=/etc/httpd/conf.d/vhost
            VHOST_AVAILABLE=/etc/httpd/conf.d/vhost
            WEB_LOG_DIR=/var/log/httpd
            APACHE_CTL="$(command -v apachectl || command -v httpd || echo /usr/sbin/httpd)"
        fi
        VHOST_FORMAT=apache
        CADDY_BIN=""
        command -v a2enmod >/dev/null 2>&1 && a2enmod proxy proxy_fcgi setenvif ssl rewrite headers >/dev/null 2>&1 || true
    fi
    if [[ "${STACK}" == "lacmp" ]] && ! command -v caddy >/dev/null 2>&1; then
        echo "Stack is LACMP but caddy was not found." >&2
        exit 1
    fi
    if [[ "${STACK}" == "lamp" ]] && ! command -v apache2 >/dev/null 2>&1 && ! command -v httpd >/dev/null 2>&1 && ! command -v apachectl >/dev/null 2>&1 && ! command -v apache2ctl >/dev/null 2>&1; then
        echo "Stack is LAMP but Apache (apache2/httpd) was not found." >&2
        exit 1
    fi
    echo "==> Stack: ${STACK} (service ${WEB_SERVICE}, vhosts ${VHOST_DIR})"
}

# Main Caddy config is a single token. Never concatenate "Caddy"+"file".
assert_caddyfile_path() {
    local p="${1:-}"
    if [[ -z "${p}" || "${p}" =~ [[:space:]] ]]; then
        echo "Caddy main-config path is missing or contains whitespace: '${p}'. Expected /etc/caddy/Caddyfile" >&2
        exit 1
    fi
    if [[ "${p}" != "/etc/caddy/Caddyfile" ]]; then
        echo "Caddy main-config path must be /etc/caddy/Caddyfile (got '${p}')." >&2
        exit 1
    fi
    if [[ ! -f "${p}" ]]; then
        echo "Caddy main-config not found: ${p}" >&2
        exit 1
    fi
}

parse_bool() {
    case "$(echo "${1:-}" | tr '[:upper:]' '[:lower:]')" in
        1|true|yes|on) echo true ;;
        0|false|no|off) echo false ;;
        *) echo ""; return 1 ;;
    esac
}

caddy_port_listening() {
    local p="$1"
    ss -tln 2>/dev/null | awk '{print $4}' | grep -Eq ":${p}$"
}

panel_snippet_uses_port() {
    local p="$1" f
    for f in \
        "${CADDY_CONFD}/lacmp-panel.conf" \
        "${VHOST_AVAILABLE:-}/lacmp-panel.conf" \
        "${VHOST_DIR:-}/lacmp-panel.conf" \
        /etc/apache2/sites-available/lacmp-panel.conf \
        /etc/httpd/conf.d/vhost/lacmp-panel.conf
    do
        [[ -n "${f}" && -f "${f}" ]] || continue
        grep -Eq ":${p}([^0-9]|$)" "${f}" && return 0
    done
    return 1
}

collect_previous_ports() {
    PREV_ALLOW_IPS=""
    if [[ -f /etc/lacmp-panel/access.env ]]; then
        PREV_ALLOW_IPS="$(grep '^PANEL_ALLOW_IPS=' /etc/lacmp-panel/access.env | cut -d= -f2- || true)"
    fi
    PREV_PORTS="$(PREFIX="${PREFIX}" CADDY_CONFD="${CADDY_CONFD}" python3 - <<'PY'
import os, re, pathlib
ports = set()
ae = pathlib.Path("/etc/lacmp-panel/access.env")
if ae.is_file():
    for line in ae.read_text().splitlines():
        if line.startswith("PANEL_PORT=") or line.startswith("TUNNEL_PORT="):
            v = line.split("=", 1)[1].strip()
            if v.isdigit():
                ports.add(int(v))
env = pathlib.Path(os.environ["PREFIX"] + "/web/.env")
if env.is_file():
    m = re.search(r"^APP_URL=.*:(\d+)\s*$", env.read_text(), re.M)
    if m:
        ports.add(int(m.group(1)))
snip = pathlib.Path(os.environ["CADDY_CONFD"] + "/lacmp-panel.conf")
if snip.is_file():
    for m in re.finditer(r"(?:https?://[^\s:{]+:|127\.0\.0\.1:)(\d+)", snip.read_text()):
        ports.add(int(m.group(1)))
print(" ".join(str(p) for p in sorted(ports)))
PY
)"
}

validate_panel_port() {
    local p="$1"
    if ! [[ "${p}" =~ ^[1-9][0-9]{0,4}$ ]] || (( p > 65535 )); then
        echo "Invalid --port=${p} (need an integer 1–65535)." >&2
        exit 2
    fi
    if [[ "${p}" == "80" || "${p}" == "443" ]]; then
        echo "Refusing to bind the panel on 80/443 (would collide with existing sites)." >&2
        exit 2
    fi
    if [[ "${p}" == "22" ]]; then
        echo "Warning: port 22 is SSH. Choose a dedicated panel port." >&2
    fi
    if (( p < 1024 )); then
        echo "Warning: port ${p} is privileged (<1024). The web server may not be able to bind it." >&2
    fi
    if [[ -d "${CADDY_CONFD}" ]]; then
        local hits
        hits="$(grep -RIl --include='*.conf' -E ":${p}([^0-9]|$)" "${CADDY_CONFD}" 2>/dev/null | grep -v '/lacmp-panel.conf$' || true)"
        if [[ -n "${hits}" ]]; then
            echo "Warning: another Caddy snippet already mentions port ${p}:" >&2
            echo "${hits}" >&2
        fi
    fi
    if command -v ss >/dev/null 2>&1 && caddy_port_listening "${p}"; then
        if panel_snippet_uses_port "${p}"; then
            return 0
        fi
        echo "Port ${p} is already in use by another listener. Choose a different --port." >&2
        ss -tln 2>/dev/null | grep -E ":${p}( |$)" >&2 || true
        exit 2
    fi
}

firewall_delete_port() {
    local p="$1"
    [[ -n "${p}" ]] || return 0
    if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "${p}/tcp" >/dev/null 2>&1 || true
        if [[ -n "${PANEL_ALLOW_IPS:-}" ]]; then
            local cidr
            IFS=',' read -ra _cidrs <<< "${PANEL_ALLOW_IPS}"
            for cidr in "${_cidrs[@]}"; do
                cidr="$(echo "${cidr}" | tr -d '[:space:]')"
                [[ -n "${cidr}" ]] || continue
                ufw --force delete allow from "${cidr}" to any port "${p}" proto tcp >/dev/null 2>&1 || true
            done
        fi
        if [[ ${#ALLOW_IPS[@]} -gt 0 ]]; then
            for cidr in "${ALLOW_IPS[@]}"; do
                ufw --force delete allow from "${cidr}" to any port "${p}" proto tcp >/dev/null 2>&1 || true
            done
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
}

usage() {
    cat <<'EOF'
Usage: lacmp_gui.sh [options]
       deploy/install.sh [options]

Access (default: tunnel — localhost 127.0.0.1:3169 + SSH; public HTTPS is optional):
  --access=tunnel|public
  --domain=<fqdn>              public domain mode (Let's Encrypt / certbot)
  --ip=<addr>                  public IP mode (self-signed). Blank in
                               interactive mode = auto-detect.
  --port=<n>                   panel listen port (default: 3169; not 80/443)
  --allow-ip=<cidr[,cidr...]>  panel + firewall allowlist (repeatable)
  --email=<addr>  --le-email=  ACME email (domain mode)

Web-server apply (default: auto):
  --caddy-reload=auto|api|systemctl|restart|none
      auto       Caddy: admin API then systemctl; Apache: graceful reload
      api        Caddy admin API only (ignored on Apache)
      systemctl  systemctl reload of the detected web server
      restart    systemctl restart (brief connection drop)
      none       write + validate; print the apply command; do not apply

Security:
  --require-totp=true|false    public default true; tunnel default false
  --firewall=true|false        default true in public (ufw / firewalld)
  --fail2ban=true|false        default true in public
  --enable-ufw                 if ufw is inactive, enable it (SSH/22 first)
  --readonly-vhost=<host>      extra read-only vhost (repeatable)

Layout:
  --prefix=<dir>               default /usr/local/lib/lacmp-panel
  --stack=auto|lacmp|lamp       default auto (detect lacmp vs lamp)
  --web-user=<user>            default: web-server unit user, else caddy/www-data
  --php=<X.Y>                  default: newest installed FPM

Operational:
  --non-interactive            no prompts; missing required values fail
  --dry-run                    print planned actions; change nothing
  --skip-caddy                 do not write the panel Caddy/Apache vhost
  --reset-db                   rotate panel DB users (destructive)
  --install-caddy-snippet      compatibility (now the default)

Public mode never serves plaintext HTTP on a public interface.
--non-interactive --access=public requires --domain= or --ip=.

Uninstall: deploy/uninstall.sh [--drop-db] [--php=X.Y]
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --reset-db) RESET_DB=1; shift ;;
        --php=*) PHP_VER="${1#*=}"; shift ;;
        --php) PHP_VER="${2:-}"; shift 2 ;;
        --prefix=*) PREFIX="${1#*=}"; shift ;;
        --prefix) PREFIX="${2:-}"; shift 2 ;;
        --stack=*) STACK="${1#*=}"; shift ;;
        --stack) STACK="${2:-}"; shift 2 ;;
        --web-user=*) WEB_USER="${1#*=}"; shift ;;
        --web-user) WEB_USER="${2:-}"; shift 2 ;;
        --install-caddy-snippet) INSTALL_CADDY_SNIPPET=1; shift ;;
        --skip-caddy) SKIP_CADDY=1; INSTALL_CADDY_SNIPPET=0; shift ;;
        --access=*) ACCESS="${1#*=}"; shift ;;
        --access) ACCESS="${2:-}"; shift 2 ;;
        --domain=*) PANEL_DOMAIN="${1#*=}"; shift ;;
        --domain) PANEL_DOMAIN="${2:-}"; shift 2 ;;
        --ip=*) PANEL_IP="${1#*=}"; shift ;;
        --ip) PANEL_IP="${2:-}"; shift 2 ;;
        --port=*) PANEL_PORT="${1#*=}"; PORT_FROM_CLI=1; shift ;;
        --port) PANEL_PORT="${2:-}"; PORT_FROM_CLI=1; shift 2 ;;
        --email=*) LE_EMAIL="${1#*=}"; shift ;;
        --email) LE_EMAIL="${2:-}"; shift 2 ;;
        --le-email=*) LE_EMAIL="${1#*=}"; shift ;;
        --le-email) LE_EMAIL="${2:-}"; shift 2 ;;
        --caddy-reload=*) CADDY_RELOAD="${1#*=}"; shift ;;
        --caddy-reload) CADDY_RELOAD="${2:-}"; shift 2 ;;
        --require-totp=*) REQUIRE_TOTP="$(parse_bool "${1#*=}" || true)"; shift ;;
        --firewall=*) DO_FIREWALL="$(parse_bool "${1#*=}" || true)"; shift ;;
        --fail2ban=*) DO_FAIL2BAN="$(parse_bool "${1#*=}" || true)"; shift ;;
        --enable-ufw) ENABLE_UFW=1; shift ;;
        --non-interactive) NON_INTERACTIVE=1; shift ;;
        --dry-run) DRY_RUN=1; shift ;;
        --allow-ip=*)
            IFS=',' read -ra _extra <<< "${1#*=}"
            ALLOW_IPS+=("${_extra[@]}")
            shift
            ;;
        --allow-ip)
            IFS=',' read -ra _extra <<< "${2:-}"
            ALLOW_IPS+=("${_extra[@]}")
            shift 2
            ;;
        --readonly-vhost=*) EXTRA_READONLY+=("${1#*=}"); shift ;;
        --readonly-vhost) EXTRA_READONLY+=("${2:-}"); shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

CADDY_RELOAD="$(echo "${CADDY_RELOAD}" | tr '[:upper:]' '[:lower:]')"
case "${CADDY_RELOAD}" in
    auto|api|systemctl|restart|none) ;;
    *) echo "Invalid --caddy-reload=${CADDY_RELOAD} (use auto|api|systemctl|restart|none)" >&2; exit 2 ;;
esac

if [[ -z "${ACCESS}" ]]; then
    if [[ "${NON_INTERACTIVE}" -eq 1 ]]; then
        ACCESS=tunnel
    elif [[ -t 0 && -t 1 ]]; then
        echo "LACMP Panel installer"
        echo "  stack   — auto-detect teddysun LACMP (Caddy) or LAMP (Apache); override with --stack="
        echo "  tunnel  — localhost ${PANEL_PORT} + SSH tunnel (default; public HTTPS is optional)"
        echo "  public  — HTTPS on a port (domain = trusted cert, or IP = self-signed)"
        read -r -p "Access mode [tunnel/public] (default: tunnel): " ACCESS
        ACCESS="${ACCESS:-tunnel}"
        if [[ "${ACCESS}" == "public" ]]; then
            read -r -p "Domain for automatic HTTPS (blank = IP / self-signed): " PANEL_DOMAIN
            if [[ "${PORT_FROM_CLI}" -eq 0 ]]; then
                read -r -p "Panel port [${PANEL_PORT}]: " _p
                PANEL_PORT="${_p:-$PANEL_PORT}"
            fi
            if [[ -n "${PANEL_DOMAIN}" ]]; then
                read -r -p "Let's Encrypt email (optional): " LE_EMAIL
            else
                read -r -p "Public IP (blank = auto-detect): " PANEL_IP
            fi
            read -r -p "Allowlist CIDRs comma-separated (blank = global + fail2ban): " _a
            if [[ -n "${_a}" ]]; then
                IFS=',' read -ra ALLOW_IPS <<< "${_a}"
            fi
            read -r -p "Caddy apply [auto/api/systemctl/restart/none] (default: auto): " _r
            CADDY_RELOAD="$(echo "${_r:-auto}" | tr '[:upper:]' '[:lower:]')"
            read -r -p "Open firewall for the panel port? [Y/n]: " _f
            [[ "${_f}" =~ ^[Nn] ]] && DO_FIREWALL=false || DO_FIREWALL=true
            read -r -p "Install fail2ban jail for failed logins? [Y/n]: " _b
            [[ "${_b}" =~ ^[Nn] ]] && DO_FAIL2BAN=false || DO_FAIL2BAN=true
        fi
        if [[ "${ACCESS}" != "public" && "${PORT_FROM_CLI}" -eq 0 ]]; then
            read -r -p "Panel port [${PANEL_PORT}]: " _p
            PANEL_PORT="${_p:-$PANEL_PORT}"
        fi
        if [[ "${ACCESS}" == "public" ]]; then
            read -r -p "Require TOTP for admins? [Y/n]: " _t
            if [[ "${_t}" =~ ^[Nn] ]]; then
                REQUIRE_TOTP=false
            else
                REQUIRE_TOTP=true
            fi
        else
            read -r -p "Require TOTP for admins? [y/N]: " _t
            if [[ "${_t}" =~ ^[Yy] ]]; then
                REQUIRE_TOTP=true
            else
                REQUIRE_TOTP=false
            fi
        fi
    else
        ACCESS=tunnel
    fi
fi
ACCESS="$(echo "${ACCESS}" | tr '[:upper:]' '[:lower:]')"
[[ "${ACCESS}" == "tunnel" || "${ACCESS}" == "public" ]] || { echo "Invalid --access=${ACCESS}" >&2; exit 2; }

if [[ -z "${REQUIRE_TOTP}" ]]; then
    if [[ "${ACCESS}" == "public" ]]; then
        REQUIRE_TOTP=true
    else
        REQUIRE_TOTP=false
    fi
fi
if [[ "${ACCESS}" == "public" ]]; then
    DO_FIREWALL="${DO_FIREWALL:-true}"
    DO_FAIL2BAN="${DO_FAIL2BAN:-true}"
else
    DO_FIREWALL="${DO_FIREWALL:-false}"
    DO_FAIL2BAN="${DO_FAIL2BAN:-false}"
fi

if [[ "${NON_INTERACTIVE}" -eq 1 && "${ACCESS}" == "public" && -z "${PANEL_DOMAIN}" && -z "${PANEL_IP}" ]]; then
    echo "--non-interactive --access=public requires --domain= or --ip= (refusing silent auto-detect)." >&2
    exit 2
fi

if [[ "${SKIP_CADDY}" -eq 0 ]]; then
    INSTALL_CADDY_SNIPPET=1
fi
if [[ "${ACCESS}" == "public" ]]; then
    INSTALL_CADDY_SNIPPET=1
    SKIP_CADDY=0
fi

detect_stack

collect_previous_ports
validate_panel_port "${PANEL_PORT}"

# trim allowlist entries
_tmp=()
for _a in "${ALLOW_IPS[@]+"${ALLOW_IPS[@]}"}"; do
    _a="$(echo "${_a}" | tr -d '[:space:]')"
    [[ -n "${_a}" ]] && _tmp+=("${_a}")
done
ALLOW_IPS=("${_tmp[@]+"${_tmp[@]}"}")

# --- identity ----------------------------------------------------------------
if [[ -z "${WEB_USER}" ]]; then
    _unit_u="$(systemctl show "${WEB_SERVICE}" -p User --value 2>/dev/null || true)"
    if [[ -n "${_unit_u}" && "${_unit_u}" != "-" && "${_unit_u}" != "root" ]] && id -u "${_unit_u}" >/dev/null 2>&1; then
        WEB_USER="${_unit_u}"
    elif [[ "${STACK}" == "lacmp" ]] && id -u caddy >/dev/null 2>&1; then
        WEB_USER=caddy
    elif id -u www-data >/dev/null 2>&1; then
        WEB_USER=www-data
    elif id -u apache >/dev/null 2>&1; then
        WEB_USER=apache
    elif id -u caddy >/dev/null 2>&1; then
        WEB_USER=caddy
    else
        echo "No web-server user found. Set WEB_USER=..." >&2
        exit 1
    fi
fi
id -u "${WEB_USER}" >/dev/null 2>&1 || { echo "WEB_USER ${WEB_USER} does not exist" >&2; exit 1; }

if [[ -z "${PHP_VER}" ]]; then
    if ls -d /etc/php/*/fpm >/dev/null 2>&1; then
        PHP_VER="$(ls -d /etc/php/*/fpm | sed 's|/etc/php/||;s|/fpm||' | sort -V | tail -n1)"
    elif command -v php >/dev/null 2>&1; then
        PHP_VER="$(php -v | head -n1 | awk '{print $2}' | cut -d. -f1-2)"
    else
        echo "Cannot detect PHP version. Pass --php=8.4" >&2
        exit 1
    fi
fi

fpm_bin() {
    local c
    for c in \
        "php-fpm${PHP_VER}" \
        "/usr/sbin/php-fpm${PHP_VER}" \
        "/usr/sbin/php-fpm" \
        "php${PHP_VER}-fpm"
    do
        if command -v "${c}" >/dev/null 2>&1; then
            command -v "${c}"
            return 0
        fi
        if [[ -x "${c}" ]]; then
            echo "${c}"
            return 0
        fi
    done
    return 1
}

fpm_unit() {
    if systemctl cat "php${PHP_VER}-fpm.service" >/dev/null 2>&1; then
        echo "php${PHP_VER}-fpm"
        return
    fi
    if systemctl cat "php-fpm.service" >/dev/null 2>&1; then
        echo "php-fpm"
        return
    fi
    echo "php${PHP_VER}-fpm"
}

# ProtectSystem=full remounts /usr (and /etc) read-only in the FPM namespace.
# The pool only needs to write panel storage/logs. Web-server config is written
# by the systemd-run broker — listing /etc/caddy on LAMP (or any missing dir)
# makes systemd fail the unit with 226/NAMESPACE.
fpm_read_write_paths() {
    local p
    local -a paths=()
    for p in \
        "${PREFIX}/web/storage" \
        "${PREFIX}/web/bootstrap/cache" \
        "/var/log/lacmp-panel"
    do
        if [[ -e "${p}" ]]; then
            paths+=("${p}")
        else
            echo "Warning: skipping ReadWritePaths (path does not exist): ${p}" >&2
        fi
    done
    (IFS=' '; echo "${paths[*]}")
}

COMPOSER_BIN="$(command -v composer || true)"
[[ -n "${COMPOSER_BIN}" ]] || { echo "composer is not on PATH (the wrapper should have installed it)" >&2; exit 1; }
PHP_BIN="$(command -v php || true)"
[[ -x "${PHP_BIN}" ]] || { echo "php CLI is not on PATH (the wrapper should have installed php-cli)" >&2; exit 1; }

# Local admin for CREATE USER.
# Debian/Ubuntu LACMP: debian-sys-maint in /etc/mysql/debian.cnf
# RHEL: unix_socket as root, or /root/.my.cnf
mariadb_admin() {
    local bin="mariadb"
    command -v mariadb >/dev/null 2>&1 || bin="mysql"
    if [[ -f /etc/mysql/debian.cnf ]]; then
        "${bin}" --defaults-file=/etc/mysql/debian.cnf "$@"
    elif [[ -f /root/.my.cnf ]]; then
        "${bin}" --defaults-file=/root/.my.cnf "$@"
    elif "${bin}" --protocol=socket -e "SELECT 1" >/dev/null 2>&1; then
        "${bin}" --protocol=socket "$@"
    else
        "${bin}" "$@"
    fi
}

detect_mysql_socket() {
    for s in /run/mysqld/mysqld.sock /var/run/mysqld/mysqld.sock /var/lib/mysql/mysql.sock /run/mysql/mysql.sock; do
        [[ -S "$s" ]] && { echo "$s"; return; }
    done
    echo "/run/mysqld/mysqld.sock"
}

detect_mariadb_cnf() {
    for f in /etc/mysql/mariadb.conf.d/50-server.cnf /etc/my.cnf.d/server.cnf /etc/my.cnf /etc/mysql/my.cnf; do
        [[ -f "$f" ]] && { echo "$f"; return; }
    done
    echo "/etc/mysql/mariadb.conf.d/50-server.cnf"
}

detect_public_ip() {
    local ip=""
    local u
    for u in https://ifconfig.me https://icanhazip.com https://api.ipify.org; do
        ip="$(curl -4 -fsS --max-time 4 "$u" 2>/dev/null | tr -d '[:space:]' || true)"
        if [[ "${ip}" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
            echo "${ip}"
            return 0
        fi
    done
    hostname -I 2>/dev/null | awk '{print $1}'
}

# Reverse-proxy / managed sites are read-only (generic; no hostnames baked in).
detect_readonly_vhosts() {
    python3 - "${VHOST_DIR:-${CADDY_CONFD}}" "${CADDY_CONFD}" "${VHOST_AVAILABLE:-}" <<'PY'
import pathlib, re, sys
out = []
seen_files = set()
for arg in sys.argv[1:]:
    confd = pathlib.Path(arg)
    if not arg or not confd.is_dir():
        continue
    for p in sorted(confd.glob("*.conf")):
        if p.name == "lacmp-panel.conf" or p in seen_files:
            continue
        seen_files.add(p)
        text = p.read_text(errors="replace")
        stripped = re.sub(r"^\s*#.*$", "", text, flags=re.M)
        is_proxy = bool(
            re.search(r"^\s*reverse_proxy\s+", stripped, re.M)
            or re.search(r"^\s*ProxyPass\s+", stripped, re.M)
        )
        if not is_proxy:
            continue
        m = re.search(r"^([^{\n]+)\{", stripped, re.M)
        if m:
            header = m.group(1).strip()
            for part in header.split(","):
                part = re.sub(r"^https?://", "", part.strip(), flags=re.I).lower()
                if part and part not in (":80", ":443") and not part.startswith("127.0.0.1"):
                    out.append(part)
        for sn in re.findall(r"^\s*ServerName\s+(\S+)", stripped, re.M):
            host = sn.strip().lower()
            if host and host not in ("_", "default"):
                out.append(host)
print(",".join(dict.fromkeys(out)))
PY
}

env_set() {
    local file="$1" key="$2" value="$3"
    python3 - "$file" "$key" "$value" <<'PY'
import pathlib, sys
path, key, value = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
text = path.read_text() if path.exists() else ""
lines, found = [], False
prefix = key + "="
for line in text.splitlines():
    if line.startswith(prefix) or line.startswith("#" + prefix):
        if not found:
            lines.append(prefix + value)
            found = True
    else:
        lines.append(line)
if not found:
    lines.append(prefix + value)
path.write_text("\n".join(lines) + "\n")
PY
}

pool_dir() {
    if [[ -d "/etc/php/${PHP_VER}/fpm/pool.d" ]]; then
        echo "/etc/php/${PHP_VER}/fpm/pool.d"
    elif [[ -d /etc/php-fpm.d ]]; then
        echo /etc/php-fpm.d
    fi
}

fpm_ini() {
    if [[ -f "/etc/php/${PHP_VER}/fpm/php.ini" ]]; then
        echo "/etc/php/${PHP_VER}/fpm/php.ini"
    elif [[ -f /etc/php.ini ]]; then
        echo /etc/php.ini
    fi
}

echo "==> Installing LACMP Panel into ${PREFIX} (php ${PHP_VER}, user ${WEB_USER}, access ${ACCESS})"

[[ -d "${ROOT}/broker/src" && -f "${ROOT}/broker/broker" && -f "${ROOT}/broker/broker.php" && -d "${ROOT}/web" ]] || {
    echo "Repo layout incomplete (need broker/ and web/). Partial clone?" >&2
    exit 1
}

MYSQL_SOCKET="$(detect_mysql_socket)"
MARIADB_CNF="$(detect_mariadb_cnf)"
if [[ "${STACK}" == "lacmp" ]]; then
    CADDY_BIN="$(command -v caddy || echo /usr/bin/caddy)"
fi

READONLY_DETECTED="$(detect_readonly_vhosts || true)"
IFS=',' read -ra _ro <<< "${READONLY_DETECTED}"
READONLY_LIST=()
for _r in "${_ro[@]+"${_ro[@]}"}"; do
    [[ -n "${_r}" ]] && READONLY_LIST+=("${_r}")
done
for _r in "${EXTRA_READONLY[@]+"${EXTRA_READONLY[@]}"}"; do
    [[ -n "${_r}" ]] && READONLY_LIST+=("${_r}")
done
# unique
_tmp=()
for _r in "${READONLY_LIST[@]+"${READONLY_LIST[@]}"}"; do
    _seen=0
    for _e in "${_tmp[@]+"${_tmp[@]}"}"; do
        [[ "${_e}" == "${_r}" ]] && _seen=1
    done
    [[ "${_seen}" -eq 0 ]] && _tmp+=("${_r}")
done
READONLY_LIST=("${_tmp[@]+"${_tmp[@]}"}")
READONLY_JSON="$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1:]))' "${READONLY_LIST[@]+"${READONLY_LIST[@]}"}")"

caddy_admin_spec() {
    python3 - "${CADDYFILE}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    print("default")
    raise SystemExit
text = path.read_text(errors="replace")
# First global options block only.
m = re.search(r"(?ms)^\s*\{(.*?)\}", text)
block = m.group(1) if m else ""
for line in block.splitlines():
    s = line.strip()
    if s.startswith("admin "):
        print(s.split(None, 1)[1].strip().strip('"'))
        raise SystemExit
print("default")
PY
}

caddy_admin_probe() {
    local spec url
    spec="$(caddy_admin_spec)"
    case "${spec}" in
        off|disabled)
            return 1
            ;;
        unix/*|unix://*)
            local sock="${spec#unix//}"
            sock="${sock#unix/}"
            curl -fsS --max-time 2 --unix-socket "${sock}" http://localhost/config/ >/dev/null 2>&1
            return $?
            ;;
        default|"")
            curl -fsS --max-time 2 http://127.0.0.1:2019/config/ >/dev/null 2>&1 && return 0
            curl -fsS --max-time 2 -g "http://[::1]:2019/config/" >/dev/null 2>&1
            return $?
            ;;
        *)
            url="${spec}"
            [[ "${url}" == http://* || "${url}" == https://* ]] || url="http://${url}"
            # Prefer IPv4 if the host is localhost (Caddy reload otherwise hits [::1]).
            url="${url/localhost/127.0.0.1}"
            curl -fsS --max-time 2 "${url%/}/config/" >/dev/null 2>&1
            return $?
            ;;
    esac
}

caddy_admin_address_flag() {
    local spec
    spec="$(caddy_admin_spec)"
    case "${spec}" in
        off|disabled) echo "" ;;
        default|"") echo "127.0.0.1:2019" ;;
        unix/*|unix://*) echo "${spec}" ;;
        *) echo "${spec/localhost/127.0.0.1}" ;;
    esac
}

ensure_caddy_running() {
    if systemctl is-active --quiet caddy; then
        return 0
    fi
    echo "==> Caddy is not active; starting unit"
    systemctl start caddy
    sleep 1
    if ! systemctl is-active --quiet caddy; then
        echo "Could not start Caddy (systemctl start caddy failed)." >&2
        return 1
    fi
}

verify_caddy_healthy() {
    local i
    systemctl is-active --quiet caddy || return 1
    if [[ "${INSTALL_CADDY_SNIPPET}" -ne 1 ]]; then
        return 0
    fi
    for i in $(seq 1 25); do
        if caddy_port_listening "${PANEL_PORT}"; then
            return 0
        fi
        sleep 0.3
    done
    echo "==> Listen check: port ${PANEL_PORT}=$(caddy_port_listening "${PANEL_PORT}" && echo up || echo down)" >&2
    return 1
}

rollback_panel_snippet() {
    local snippet="$1" bak="$2"
    if [[ -n "${bak}" && -f "${bak}" ]]; then
        mv -f "${bak}" "${snippet}"
        echo "==> Restored previous panel Caddy snippet"
    else
        rm -f "${snippet}"
        echo "==> Removed new panel Caddy snippet (no previous snippet)"
    fi
}

broker_caddy_apply() {
    local payload out rc=0
    payload="$(python3 -c 'import json,os; print(json.dumps({"mode":os.environ["M"],"expect_ports":[int(p) for p in os.environ["P"].split(",") if p.strip()]}))')"
    set +e
    out="$("${PREFIX}/broker" caddy.apply <<<"${payload}")"
    rc=$?
    set -e
    printf '%s\n' "${out}"
    if [[ "${rc}" -ne 0 ]]; then
        return 1
    fi
    python3 -c 'import json,sys; raw=sys.stdin.read().strip();
raise SystemExit(1 if not raw else (0 if json.loads(raw).get("ok") else 1))' <<<"${out}"
}

caddy_apply() {
    local snippet="$1" bak="$2"
    local ports="${PANEL_PORT}"

    echo "==> Caddy apply strategy: ${CADDY_RELOAD} (shared broker caddy.apply)"

    if [[ "${CADDY_RELOAD}" == "none" ]]; then
        echo "Caddy snippet written and validated. Not applying (--caddy-reload=none)."
        echo "Apply manually with one of:"
        echo "  ${PREFIX}/broker caddy.apply   # stdin: {\"mode\":\"auto\",\"expect_ports\":[${PANEL_PORT}]}"
        echo "  ${CADDY_BIN} reload --config ${CADDYFILE} --address 127.0.0.1:2019 --force"
        echo "  systemctl reload caddy"
        echo "  systemctl restart caddy"
        return 0
    fi

    if ! ensure_caddy_running; then
        rollback_panel_snippet "${snippet}" "${bak}"
        return 1
    fi

    export M="${CADDY_RELOAD}" P="${ports}"
    if ! broker_caddy_apply; then
        echo "Caddy apply failed via broker; rolling back the panel snippet." >&2
        rollback_panel_snippet "${snippet}" "${bak}"
        export M=auto P=""
        broker_caddy_apply >/dev/null 2>&1 || true
        return 1
    fi
    unset M P

    if ! verify_caddy_healthy; then
        echo "Caddy is not healthy after apply; rolling back the panel snippet." >&2
        rollback_panel_snippet "${snippet}" "${bak}"
        export M=auto P=""
        broker_caddy_apply >/dev/null 2>&1 || true
        unset M P
        return 1
    fi
    return 0
}

apache_apply() {
    local snippet="$1" bak="$2" listen="${3:-}"
    echo "==> Apache apply (systemctl reload ${WEB_SERVICE})"
    if [[ "${CADDY_RELOAD}" == "none" ]]; then
        echo "Apache vhost written and not applied (--caddy-reload=none)."
        return 0
    fi
    if ! systemctl is-active --quiet "${WEB_SERVICE}"; then
        echo "==> ${WEB_SERVICE} is not active; starting unit"
        systemctl start "${WEB_SERVICE}"
        sleep 1
        if ! systemctl is-active --quiet "${WEB_SERVICE}"; then
            rollback_panel_snippet "${snippet}" "${bak}"
            [[ -n "${listen}" && -f "${listen}" ]] && rm -f "${listen}"
            echo "Could not start ${WEB_SERVICE}." >&2
            return 1
        fi
    fi
    if command -v a2ensite >/dev/null 2>&1 && [[ -f "${VHOST_AVAILABLE}/lacmp-panel.conf" ]]; then
        a2ensite lacmp-panel >/dev/null 2>&1 || a2ensite lacmp-panel.conf >/dev/null 2>&1 || true
    fi
    if command -v a2enconf >/dev/null 2>&1 && [[ -n "${listen}" && -f "${listen}" ]]; then
        a2enconf lacmp-panel-listen >/dev/null 2>&1 || true
    fi
    if ! "${APACHE_CTL}" -t; then
        echo "Apache configtest failed; rolling back the panel vhost." >&2
        rollback_panel_snippet "${snippet}" "${bak}"
        command -v a2dissite >/dev/null 2>&1 && a2dissite lacmp-panel >/dev/null 2>&1 || true
        [[ -n "${listen}" && -f "${listen}" ]] && rm -f "${listen}"
        "${APACHE_CTL}" -t >/dev/null 2>&1 && systemctl reload "${WEB_SERVICE}" >/dev/null 2>&1 || systemctl start "${WEB_SERVICE}" >/dev/null 2>&1 || true
        return 1
    fi
    if ! systemctl reload "${WEB_SERVICE}"; then
        echo "systemctl reload ${WEB_SERVICE} failed; trying start." >&2
        systemctl start "${WEB_SERVICE}" || true
    fi
    sleep 1
    if ! systemctl is-active --quiet "${WEB_SERVICE}"; then
        systemctl start "${WEB_SERVICE}" || true
        sleep 1
    fi
    if ! systemctl is-active --quiet "${WEB_SERVICE}"; then
        echo "${WEB_SERVICE} is not active after apply; rolling back." >&2
        rollback_panel_snippet "${snippet}" "${bak}"
        command -v a2dissite >/dev/null 2>&1 && a2dissite lacmp-panel >/dev/null 2>&1 || true
        [[ -n "${listen}" && -f "${listen}" ]] && rm -f "${listen}"
        systemctl start "${WEB_SERVICE}" >/dev/null 2>&1 || true
        return 1
    fi
    local i
    for i in $(seq 1 25); do
        if caddy_port_listening "${PANEL_PORT}"; then
            return 0
        fi
        sleep 0.3
    done
    echo "Port ${PANEL_PORT} is not listening after Apache reload; rolling back." >&2
    rollback_panel_snippet "${snippet}" "${bak}"
    command -v a2dissite >/dev/null 2>&1 && a2dissite lacmp-panel >/dev/null 2>&1 || true
    "${APACHE_CTL}" -t >/dev/null 2>&1 && systemctl reload "${WEB_SERVICE}" >/dev/null 2>&1 || true
    return 1
}

if [[ "${DRY_RUN}" -eq 1 ]]; then
    echo "DRY-RUN — no files, packages, or services will be changed."
    echo "  prefix:        ${PREFIX}"
    echo "  web user:      ${WEB_USER}"
    echo "  stack:         ${STACK}"
    echo "  web service:   ${WEB_SERVICE}"
    echo "  php:           ${PHP_VER}"
    echo "  access:        ${ACCESS}"
    echo "  port:          ${PANEL_PORT}"
    echo "  domain/ip:     ${PANEL_DOMAIN:-}${PANEL_IP:-auto-if-interactive}"
    echo "  apply:         ${CADDY_RELOAD}"
    echo "  require totp:  ${REQUIRE_TOTP}"
    echo "  firewall:      ${DO_FIREWALL}"
    echo "  fail2ban:      ${DO_FAIL2BAN}"
    echo "  panel vhost:   ${VHOST_DIR}/lacmp-panel.conf"
    echo "  fpm pool:      $(pool_dir 2>/dev/null || echo unknown)/lacmp-panel.conf"
    echo "  sudoers:       /etc/sudoers.d/lacmp-panel"
    echo "  readonly:      ${READONLY_JSON}"
    if [[ "${STACK}" == "lacmp" ]]; then
        echo "  caddy admin:   $(caddy_admin_spec 2>/dev/null || echo unknown)"
        echo "  caddy active:  $(systemctl is-active caddy 2>/dev/null || echo unknown)"
    else
        echo "  apache active: $(systemctl is-active "${WEB_SERVICE}" 2>/dev/null || echo unknown)"
    fi
    exit 0
fi

# --- layout / permissions ----------------------------------------------------
# PREFIX 0751 root:root: web user can *traverse* into web/ but cannot list PREFIX
# or read broker/src. Broker binary 0750 root:root. web/ owned by WEB_USER.
install -d -m 0751 -o root -g root "${PREFIX}"
install -d -m 0750 -o root -g root "${PREFIX}/src"
install -d -m 0750 -o root -g root /etc/lacmp-panel
# 0770 so the FPM user can write php-fpm.log; broker-audit.log stays root:root.
install -d -m 0770 -o root -g "${WEB_USER}" /var/log/lacmp-panel
touch /var/log/lacmp-panel/php-fpm.log
chown "${WEB_USER}:${WEB_USER}" /var/log/lacmp-panel/php-fpm.log
chmod 0640 /var/log/lacmp-panel/php-fpm.log
touch /var/log/lacmp-panel/auth-fail.log
chown "${WEB_USER}:${WEB_USER}" /var/log/lacmp-panel/auth-fail.log
chmod 0640 /var/log/lacmp-panel/auth-fail.log
if [[ "${STACK}" == "lacmp" ]]; then
    install -d -m 0755 -o "${WEB_USER}" -g "${WEB_USER}" /var/log/caddy
fi
install -d -m 0750 -o root -g root /var/lib/lacmp-panel
install -d -m 0750 -o root -g root /var/lib/lacmp-panel/staging

rm -rf "${PREFIX}/src"
cp -a "${ROOT}/broker/src" "${PREFIX}/src"
chown -R root:root "${PREFIX}/src"
chmod -R go-rwx "${PREFIX}/src"
find "${PREFIX}/src" -type d -exec chmod 0750 {} \;
find "${PREFIX}/src" -type f -exec chmod 0640 {} \;
install -m 0750 -o root -g root "${ROOT}/broker/broker" "${PREFIX}/broker"
install -m 0640 -o root -g root "${ROOT}/broker/broker.php" "${PREFIX}/broker.php"

# --- sudoers (templated to the actual WEB_USER + PREFIX) ---------------------
SUDOERS=/etc/sudoers.d/lacmp-panel
TMP_SUDOERS="$(mktemp)"
cat > "${TMP_SUDOERS}" <<EOF
# LACMP Panel — sudoers (generated by install.sh)
# ${WEB_USER} may run ONLY this broker, as root, with no password.
Defaults:${WEB_USER} !requiretty
Defaults:${WEB_USER} umask=0022
${WEB_USER} ALL=(root) NOPASSWD: ${PREFIX}/broker
EOF
chmod 0440 "${TMP_SUDOERS}"
if ! visudo -c -f "${TMP_SUDOERS}" >/dev/null; then
    rm -f "${TMP_SUDOERS}"
    echo "sudoers validation failed; aborting" >&2
    exit 1
fi
install -m 0440 -o root -g root "${TMP_SUDOERS}" "${SUDOERS}"
rm -f "${TMP_SUDOERS}"
visudo -c >/dev/null

# --- MariaDB panel admin + app user -----------------------------------------
PANEL_DB="lacmp_panel"
PANEL_USER="lacmp_panel"
ADMIN_USER="lacmp_panel_admin"
APP_PASS=""

if [[ ! -f /etc/lacmp-panel/broker.json || "${RESET_DB}" -eq 1 ]]; then
    ADMIN_PASS="$(openssl rand -hex 32)"
    APP_PASS="$(openssl rand -hex 24)"
    mariadb_admin <<SQL
CREATE DATABASE IF NOT EXISTS \`${PANEL_DB}\` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'localhost' IDENTIFIED BY '${ADMIN_PASS}';
CREATE USER IF NOT EXISTS '${ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${ADMIN_PASS}';
ALTER USER '${ADMIN_USER}'@'localhost' IDENTIFIED BY '${ADMIN_PASS}';
ALTER USER '${ADMIN_USER}'@'127.0.0.1' IDENTIFIED BY '${ADMIN_PASS}';
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'localhost' WITH GRANT OPTION;
GRANT ALL PRIVILEGES ON *.* TO '${ADMIN_USER}'@'127.0.0.1' WITH GRANT OPTION;
CREATE USER IF NOT EXISTS '${PANEL_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
CREATE USER IF NOT EXISTS '${PANEL_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_PASS}';
ALTER USER '${PANEL_USER}'@'localhost' IDENTIFIED BY '${APP_PASS}';
ALTER USER '${PANEL_USER}'@'127.0.0.1' IDENTIFIED BY '${APP_PASS}';
GRANT ALL PRIVILEGES ON \`${PANEL_DB}\`.* TO '${PANEL_USER}'@'localhost';
GRANT ALL PRIVILEGES ON \`${PANEL_DB}\`.* TO '${PANEL_USER}'@'127.0.0.1';
FLUSH PRIVILEGES;
SQL
    umask 077
    # observed_services: extra systemd units or 127.0.0.1:<port> to list as
    # observed (no-control). Default []. Example:
    #   "observed_services": ["custom-worker", "127.0.0.1:9000"]
    cat > /etc/lacmp-panel/broker.json <<EOF
{
    "stack": "${STACK}",
    "web_server": "${WEB_SERVICE}",
    "web_service": "${WEB_SERVICE}",
    "vhost_format": "${VHOST_FORMAT}",
    "paths": {
        "www_root": "${WWW_ROOT}",
$(if [[ "${STACK}" == "lacmp" ]]; then printf '%s\n' "        \"caddy_confd\": \"${CADDY_CONFD}\"," "        \"caddyfile\": \"${CADDYFILE}\"," "        \"caddy_bin\": \"${CADDY_BIN}\","; fi)
        "vhost_dir": "${VHOST_DIR}",
        "vhost_available": "${VHOST_AVAILABLE}",
        "web_log_dir": "${WEB_LOG_DIR}",
        "apache_ctl": "${APACHE_CTL}",
        "audit_log": "/var/log/lacmp-panel/broker-audit.log",
        "mariadb_server_cnf": "${MARIADB_CNF}",
        "artisan": "${PREFIX}/web/artisan",
        "staging_dir": "/var/lib/lacmp-panel/staging",
        "cron_d": "/etc/cron.d/lacmp-panel",
        "panel_root": "${PREFIX}"
    },
    "web_user": "${WEB_USER}",
    "mariadb": {
        "socket": "${MYSQL_SOCKET}",
        "user": "${ADMIN_USER}",
        "password": "${ADMIN_PASS}"
    },
    "readonly_vhosts": ${READONLY_JSON},
    "observed_services": []
}
EOF
    chmod 0600 /etc/lacmp-panel/broker.json
    chown root:root /etc/lacmp-panel/broker.json
    unset ADMIN_PASS
else
    echo "Keeping existing /etc/lacmp-panel/broker.json (pass --reset-db to rotate)."
    LACMP_READONLY_JSON="${READONLY_JSON}" \
    LACMP_WWW_ROOT="${WWW_ROOT}" \
    LACMP_CADDY_CONFD="${CADDY_CONFD}" \
    LACMP_CADDY_BIN="${CADDY_BIN:-}" \
    LACMP_ARTISAN="${PREFIX}/web/artisan" \
    LACMP_PREFIX="${PREFIX}" \
    LACMP_WEB_USER="${WEB_USER}" \
    LACMP_STACK="${STACK}" \
    LACMP_WEB_SERVICE="${WEB_SERVICE}" \
    LACMP_VHOST_FORMAT="${VHOST_FORMAT}" \
    LACMP_VHOST_DIR="${VHOST_DIR}" \
    LACMP_VHOST_AVAILABLE="${VHOST_AVAILABLE}" \
    LACMP_WEB_LOG_DIR="${WEB_LOG_DIR}" \
    LACMP_APACHE_CTL="${APACHE_CTL}" \
    python3 - /etc/lacmp-panel/broker.json <<'PY'
import json, os, pathlib, sys
path = pathlib.Path(sys.argv[1])
data = json.loads(path.read_text())
data["readonly_vhosts"] = json.loads(os.environ["LACMP_READONLY_JSON"])
data["stack"] = os.environ["LACMP_STACK"]
data["web_server"] = os.environ["LACMP_WEB_SERVICE"]
data["web_service"] = os.environ["LACMP_WEB_SERVICE"]
data["vhost_format"] = os.environ["LACMP_VHOST_FORMAT"]
data.setdefault("paths", {})["www_root"] = os.environ["LACMP_WWW_ROOT"]
if os.environ.get("LACMP_STACK") == "lacmp":
    data["paths"]["caddy_confd"] = os.environ["LACMP_CADDY_CONFD"]
    data["paths"]["caddyfile"] = "/etc/caddy/Caddyfile"
    if os.environ.get("LACMP_CADDY_BIN"):
        data["paths"]["caddy_bin"] = os.environ["LACMP_CADDY_BIN"]
else:
    for key in ("caddy_confd", "caddyfile", "caddy_bin"):
        data["paths"].pop(key, None)
data["paths"]["artisan"] = os.environ["LACMP_ARTISAN"]
data["paths"]["panel_root"] = os.environ["LACMP_PREFIX"]
data["paths"]["vhost_dir"] = os.environ["LACMP_VHOST_DIR"]
data["paths"]["vhost_available"] = os.environ["LACMP_VHOST_AVAILABLE"]
data["paths"]["web_log_dir"] = os.environ["LACMP_WEB_LOG_DIR"]
if os.environ.get("LACMP_APACHE_CTL"):
    data["paths"]["apache_ctl"] = os.environ["LACMP_APACHE_CTL"]
data["web_user"] = os.environ["LACMP_WEB_USER"]
data.setdefault("observed_services", [])
path.write_text(json.dumps(data, indent=4) + "\n")
PY
    chmod 0600 /etc/lacmp-panel/broker.json
    chown root:root /etc/lacmp-panel/broker.json
fi

# --- web app (preserve .env / storage across re-runs) ------------------------
install -d -m 0750 -o "${WEB_USER}" -g "${WEB_USER}" "${PREFIX}/web"
rsync -a --delete \
    --exclude '.env' \
    --exclude 'vendor/' \
    --exclude 'node_modules/' \
    --exclude 'tests/' \
    --exclude 'bootstrap/cache/*.php' \
    --exclude 'storage/logs/' \
    --exclude 'storage/framework/cache/' \
    --exclude 'storage/framework/sessions/' \
    --exclude 'storage/framework/views/' \
    --exclude 'storage/framework/tmp/' \
    --exclude '.phpunit.cache/' \
    "${ROOT}/web/" "${PREFIX}/web/"

# HTTP-layer Validator copy (no secrets). Privileged src/ stays 0750 root:root.
install -d -m 0750 -o "${WEB_USER}" -g "${WEB_USER}" "${PREFIX}/web/lib/lacmp-broker"
rsync -a --delete "${ROOT}/broker/src/" "${PREFIX}/web/lib/lacmp-broker/"

install -d -m 0770 -o "${WEB_USER}" -g "${WEB_USER}" \
    "${PREFIX}/web/storage" \
    "${PREFIX}/web/storage/logs" \
    "${PREFIX}/web/storage/framework" \
    "${PREFIX}/web/storage/framework/cache" \
    "${PREFIX}/web/storage/framework/cache/data" \
    "${PREFIX}/web/storage/framework/sessions" \
    "${PREFIX}/web/storage/framework/views" \
    "${PREFIX}/web/storage/framework/tmp" \
    "${PREFIX}/web/storage/app" \
    "${PREFIX}/web/bootstrap/cache"
# keep directory placeholders git ships
find "${PREFIX}/web/storage" "${PREFIX}/web/bootstrap/cache" -type d -exec chmod 0770 {} \;
chown -R "${WEB_USER}:${WEB_USER}" "${PREFIX}/web"
# rsync -a copies git's 0755 dirs; lock the tree down so other local users
# cannot read the app even though PREFIX is traversable (0751).
find "${PREFIX}/web" -type d -exec chmod 0750 {} \;
find "${PREFIX}/web" -type f -exec chmod 0640 {} \;
find "${PREFIX}/web/storage" "${PREFIX}/web/bootstrap/cache" -type d -exec chmod 0770 {} \;
chmod 0750 "${PREFIX}/web" "${PREFIX}/web/public"
# artisan must stay executable for the scheduler cron
chmod 0750 "${PREFIX}/web/artisan"

if [[ ! -f "${PREFIX}/web/.env" && -f /etc/lacmp-panel/web.env && "${RESET_DB}" -eq 0 ]]; then
    echo "Restoring web .env preserved from a previous uninstall."
    install -m 0640 -o "${WEB_USER}" -g "${WEB_USER}" /etc/lacmp-panel/web.env "${PREFIX}/web/.env"
fi
if [[ ! -f "${PREFIX}/web/.env" ]]; then
    cp "${ROOT}/web/.env.example" "${PREFIX}/web/.env"
    env_set "${PREFIX}/web/.env" BROKER_DRIVER sudo
    env_set "${PREFIX}/web/.env" BROKER_PATH "${PREFIX}/broker"
    env_set "${PREFIX}/web/.env" APP_ENV production
    env_set "${PREFIX}/web/.env" APP_DEBUG false
    env_set "${PREFIX}/web/.env" DB_SOCKET "${MYSQL_SOCKET}"
    env_set "${PREFIX}/web/.env" LACMP_WWW_ROOT "${WWW_ROOT}"
fi
if [[ -n "${APP_PASS}" ]]; then
    env_set "${PREFIX}/web/.env" DB_PASSWORD "${APP_PASS}"
fi

if [[ "${ACCESS}" == "public" ]]; then
    env_set "${PREFIX}/web/.env" SESSION_SECURE_COOKIE true
    env_set "${PREFIX}/web/.env" PANEL_REQUIRE_TOTP "${REQUIRE_TOTP}"
    env_set "${PREFIX}/web/.env" TRUSTED_PROXIES 127.0.0.1
else
    env_set "${PREFIX}/web/.env" APP_URL "http://127.0.0.1:${PANEL_PORT}"
    env_set "${PREFIX}/web/.env" SESSION_SECURE_COOKIE false
    env_set "${PREFIX}/web/.env" PANEL_REQUIRE_TOTP "${REQUIRE_TOTP}"
    env_set "${PREFIX}/web/.env" TRUSTED_PROXIES 127.0.0.1
fi
chown "${WEB_USER}:${WEB_USER}" "${PREFIX}/web/.env"
chmod 0640 "${PREFIX}/web/.env"

COMPOSER_HOME="$(mktemp -d /tmp/lacmp-composer.XXXXXX)"
chown "${WEB_USER}:${WEB_USER}" "${COMPOSER_HOME}"
export COMPOSER_HOME
run_as_web() {
    # bash -c (not -lc): WEB_USER often has nologin as its login shell.
    sudo -u "${WEB_USER}" -H env COMPOSER_HOME="${COMPOSER_HOME}" \
        PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin" \
        bash -c "cd '${PREFIX}/web' && $*"
}

LOCK_HASH_FILE="/var/lib/lacmp-panel/composer.lock.sha256"
LOCK_NOW=""
if [[ -f "${PREFIX}/web/composer.lock" ]]; then
    LOCK_NOW="$(sha256sum "${PREFIX}/web/composer.lock" | awk '{print $1}')"
fi
NEED_COMPOSER=1
if [[ -f "${PREFIX}/web/vendor/autoload.php" && -n "${LOCK_NOW}" && -f "${LOCK_HASH_FILE}" ]]; then
    if [[ "$(cat "${LOCK_HASH_FILE}")" == "${LOCK_NOW}" ]]; then
        NEED_COMPOSER=0
    fi
fi
if [[ "${NEED_COMPOSER}" -eq 1 ]]; then
    echo "==> composer install --no-dev --optimize-autoloader"
    run_as_web "${PHP_BIN} ${COMPOSER_BIN} install --no-dev --optimize-autoloader --no-interaction --no-scripts"
    if [[ -n "${LOCK_NOW}" ]]; then
        printf '%s\n' "${LOCK_NOW}" > "${LOCK_HASH_FILE}"
        chmod 0640 "${LOCK_HASH_FILE}"
        chown root:root "${LOCK_HASH_FILE}"
    fi
else
    echo "==> vendor/ matches composer.lock — skipping composer install"
fi
# Always rediscover packages so a Mac --dev cache (Pail, etc.) cannot leak into production.
rm -f "${PREFIX}/web/bootstrap/cache/packages.php" "${PREFIX}/web/bootstrap/cache/services.php"
run_as_web "${PHP_BIN} artisan package:discover --ansi --no-interaction"
run_as_web "${PHP_BIN} ${COMPOSER_BIN} dump-autoload -o --no-interaction --no-scripts"
rm -rf "${COMPOSER_HOME}"

if ! grep -q '^APP_KEY=base64:' "${PREFIX}/web/.env"; then
    run_as_web "${PHP_BIN} artisan key:generate --force --no-interaction"
else
    echo "Keeping existing APP_KEY (encrypted settings depend on it)."
fi
run_as_web "${PHP_BIN} artisan migrate --force --no-interaction"
touch "${PREFIX}/web/storage/logs/laravel.log"
chown "${WEB_USER}:${WEB_USER}" "${PREFIX}/web/storage/logs/laravel.log"
chmod 0660 "${PREFIX}/web/storage/logs/laravel.log"
run_as_web "${PHP_BIN} artisan view:cache --no-interaction" || true
run_as_web "${PHP_BIN} artisan config:clear --no-interaction" || true

# --- dedicated FPM pool + public-pool lockdown -------------------------------
POOL_DIR="$(pool_dir)"
FPM_INI="$(fpm_ini)"
if [[ -n "${POOL_DIR}" && -d "${POOL_DIR}" ]]; then
    if [[ -n "${FPM_INI}" && -f "${FPM_INI}" ]] && grep -Eq '^disable_functions[[:space:]]*=' "${FPM_INI}"; then
        if grep -Eq '^disable_functions[[:space:]]*=.*(proc_open|proc_get_status)' "${FPM_INI}"; then
            # Keep the first backup forever so uninstall can restore.
            if [[ ! -f "${FPM_INI}.lacmp-panel.bak" ]]; then
                cp -a "${FPM_INI}" "${FPM_INI}.lacmp-panel.bak"
            fi
            python3 - "${FPM_INI}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
blocked = {"proc_open", "proc_get_status"}
def repl(match: re.Match[str]) -> str:
    funcs = [f.strip() for f in match.group(1).split(",") if f.strip() and f.strip() not in blocked]
    seen, out = set(), []
    for f in funcs:
        if f not in seen:
            seen.add(f)
            out.append(f)
    return "disable_functions = " + ",".join(out)
new, n = re.subn(r"^disable_functions\s*=\s*(.*)$", repl, text, count=1, flags=re.M)
if n != 1:
    raise SystemExit("failed to edit disable_functions in " + str(path))
path.write_text(new)
PY
        fi
    fi
    # Re-lock EVERY public pool, not just www.conf — stripping proc_open from
    # php.ini would otherwise leak it to any pool that relies on the global list.
    python3 - "${POOL_DIR}" <<'PY'
import pathlib, re, sys
pool_dir = pathlib.Path(sys.argv[1])
block = """
; --- LACMP-PANEL-LOCKDOWN-BEGIN ---
; proc_open/proc_get_status were removed from php.ini so the panel pool
; can use Symfony Process. Public sites keep the original lockdown.
php_admin_value[disable_functions] = passthru,exec,shell_exec,system,chroot,chgrp,chown,proc_open,proc_get_status,ini_alter,ini_restore
; --- LACMP-PANEL-LOCKDOWN-END ---
"""
for path in sorted(pool_dir.glob("*.conf")):
    if path.name == "lacmp-panel.conf":
        continue
    text = path.read_text()
    if "; --- LACMP-PANEL-LOCKDOWN-BEGIN ---" in text:
        text = re.sub(
            r"\n?; --- LACMP-PANEL-LOCKDOWN-BEGIN ---.*?--- LACMP-PANEL-LOCKDOWN-END ---\n?",
            block,
            text,
            count=1,
            flags=re.S,
        )
    else:
        text = text.rstrip() + "\n" + block
    path.write_text(text if text.endswith("\n") else text + "\n")
PY

    cat > "${POOL_DIR}/lacmp-panel.conf" <<EOF
; LACMP Panel dedicated PHP-FPM pool (generated by install.sh).
; Isolated from www.conf. shell_exec / system / exec stay disabled.
; Do not add proc_open to disable_functions here — php.ini already
; dropped it so this pool can use Symfony Process.

[lacmp-panel]
user = ${WEB_USER}
group = ${WEB_USER}
listen = /run/php/lacmp-panel.sock
listen.owner = ${WEB_USER}
listen.group = ${WEB_USER}
listen.mode = 0660

pm = ondemand
pm.max_children = 4
pm.process_idle_timeout = 10s
pm.max_requests = 200

php_admin_value[disable_functions] = passthru,exec,shell_exec,system,chroot,chgrp,chown,ini_alter,ini_restore
php_admin_flag[expose_php] = off
php_admin_value[open_basedir] = ${PREFIX}/web:/tmp:/dev/urandom:/usr/bin/sudo:/var/log/lacmp-panel
php_admin_value[sys_temp_dir] = ${PREFIX}/web/storage/framework/tmp
php_admin_value[upload_tmp_dir] = ${PREFIX}/web/storage/framework/tmp
php_admin_value[session.save_path] = ${PREFIX}/web/storage/framework/sessions
php_admin_flag[log_errors] = on
php_admin_value[error_log] = /var/log/lacmp-panel/php-fpm.log
EOF
    chmod 0644 "${POOL_DIR}/lacmp-panel.conf"

    FPM_BIN="$(fpm_bin)" || { echo "php-fpm binary for ${PHP_VER} not found" >&2; exit 1; }
    install -d -m 0755 /run/php
    cat > /etc/tmpfiles.d/lacmp-panel.conf <<EOF
d /run/php 0755 ${WEB_USER} ${WEB_USER} -
EOF
    systemd-tmpfiles --create /etc/tmpfiles.d/lacmp-panel.conf >/dev/null 2>&1 || true
    "${FPM_BIN}" -t
    UNIT="$(fpm_unit)"
    RW_PATHS="$(fpm_read_write_paths)"
    install -d -m 0755 "/etc/systemd/system/${UNIT}.service.d"
    if [[ -n "${RW_PATHS}" ]]; then
        cat > "/etc/systemd/system/${UNIT}.service.d/lacmp-panel.conf" <<EOF
[Service]
ReadWritePaths=${RW_PATHS}
EOF
    else
        echo "Warning: no existing paths for FPM ReadWritePaths; not writing a drop-in." >&2
        rm -f "/etc/systemd/system/${UNIT}.service.d/lacmp-panel.conf"
    fi
    systemctl daemon-reload
    systemctl restart "${UNIT}"
else
    echo "Warning: PHP-FPM pool directory not found; skip FPM pool. Panel cannot call the broker without proc_open." >&2
fi

# --- scheduler cron (idempotent; same body as broker scheduler.install) ------
cat > /etc/cron.d/lacmp-panel <<EOF
# LACMP Panel — Laravel scheduler (idempotent)
SHELL=/bin/sh
PATH=/usr/sbin:/usr/bin:/sbin:/bin
* * * * * ${WEB_USER} ${PHP_BIN} ${PREFIX}/web/artisan schedule:run >/dev/null 2>&1
EOF
chmod 0644 /etc/cron.d/lacmp-panel

# --- Caddy snippets (localhost tunnel always; optional public HTTPS) ---------
if [[ "${INSTALL_CADDY_SNIPPET}" -eq 1 ]]; then
    if [[ "${ACCESS}" == "public" ]]; then
        if [[ -n "${PANEL_DOMAIN}" && -n "${PANEL_IP}" ]]; then
            echo "Use --domain or --ip, not both." >&2
            exit 2
        fi
        if [[ -z "${PANEL_DOMAIN}" && -z "${PANEL_IP}" ]]; then
            PANEL_IP="$(detect_public_ip)"
            [[ -n "${PANEL_IP}" ]] || { echo "Could not detect a public IP. Pass --ip=..." >&2; exit 1; }
        fi
        if [[ -n "${PANEL_DOMAIN}" ]]; then
            env_set "${PREFIX}/web/.env" APP_URL "https://${PANEL_DOMAIN}:${PANEL_PORT}"
        else
            env_set "${PREFIX}/web/.env" APP_URL "https://${PANEL_IP}:${PANEL_PORT}"
        fi
        chown "${WEB_USER}:${WEB_USER}" "${PREFIX}/web/.env"
    fi

    if [[ "${STACK}" == "lacmp" ]]; then
    install -d -m 0755 -o "${WEB_USER}" -g "${WEB_USER}" /var/log/caddy
    touch /var/log/caddy/access_lacmp-panel.log /var/log/caddy/lacmp-panel.log
    chown "${WEB_USER}:${WEB_USER}" /var/log/caddy/access_lacmp-panel.log /var/log/caddy/lacmp-panel.log
    chmod 0640 /var/log/caddy/access_lacmp-panel.log /var/log/caddy/lacmp-panel.log

    SNIPPET="${CADDY_CONFD}/lacmp-panel.conf"
    install -d -m 0755 "${CADDY_CONFD}"
    BAK=""
    if [[ -e "${SNIPPET}" ]]; then
        BAK="${SNIPPET}.lacmp-bak"
        cp -a "${SNIPPET}" "${BAK}"
    fi

    ALLOW_CSV="$(IFS=','; echo "${ALLOW_IPS[*]+"${ALLOW_IPS[*]}"}")"
    python3 - "${SNIPPET}" "${PREFIX}" "${PANEL_PORT}" "${ACCESS}" \
        "${PANEL_DOMAIN}" "${PANEL_IP}" "${LE_EMAIL}" "${ALLOW_CSV}" <<'PY'
import pathlib, sys
snippet, prefix, port, access, domain, ip, email, allow_csv = sys.argv[1:9]
allow = [a.strip() for a in allow_csv.split(",") if a.strip()]
web = prefix + "/web/public"
sock = "unix//run/php/lacmp-panel.sock"
log_block = """    log {
        output file /var/log/caddy/access_lacmp-panel.log {
            roll_size 16mb
            roll_keep 3
            roll_keep_for 7d
        }
    }"""
acl = ""
if allow:
    acl = (
        "    @blocked not remote_ip " + " ".join(allow) + "\n"
        "    respond @blocked \"Forbidden\" 403\n"
    )
headers_common = """    header {
        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
        -Server
    }"""
parts = []
parts.append(f"""# LACMP Panel — generated by install.sh
# Localhost HTTP is the SSH-tunnel fallback (never 0.0.0.0).

http://127.0.0.1:{port} {{
    bind 127.0.0.1
    encode gzip zstd
    root * {web}
    php_fastcgi {sock}
    file_server
{headers_common}
{log_block}
}}
""")
if access == "public":
    if domain:
        site = domain if port in ("443", "80") else f"{domain}:{port}"
        tls = ""
        if email:
            tls = f"""    tls {{
        issuer acme {{
            email {email}
        }}
    }}
"""
        hsts = """        Strict-Transport-Security "max-age=31536000; includeSubDomains"\n"""
        parts.append(f"""
https://{site} {{
{acl}    encode gzip zstd
    root * {web}
    php_fastcgi {sock}
    file_server
    header {{
{hsts}        X-Content-Type-Options nosniff
        X-Frame-Options DENY
        Referrer-Policy no-referrer
        -Server
    }}
{tls}    log {{
        output file /var/log/caddy/lacmp-panel.log {{
            roll_size 16mb
            roll_keep 3
            roll_keep_for 7d
        }}
    }}
}}
""")
    else:
        site = f"{ip}:{port}"
        parts.append(f"""
https://{site} {{
    tls internal
{acl}    encode gzip zstd
    root * {web}
    php_fastcgi {sock}
    file_server
{headers_common}
    log {{
        output file /var/log/caddy/lacmp-panel.log {{
            roll_size 16mb
            roll_keep 3
            roll_keep_for 7d
        }}
    }}
}}
""")
pathlib.Path(snippet).write_text("".join(parts))
PY
    chmod 0644 "${SNIPPET}"
    assert_caddyfile_path "${CADDYFILE}"
    if ! "${CADDY_BIN}" validate --config "${CADDYFILE}"; then
        rollback_panel_snippet "${SNIPPET}" "${BAK}"
        echo "Caddy validate failed; panel snippet was rolled back." >&2
        exit 1
    fi
    echo "Valid configuration"
    if ! caddy_apply "${SNIPPET}" "${BAK}"; then
        echo "Caddy apply failed after validate. Existing sites should still be served." >&2
        exit 1
    fi
    if [[ "${CADDY_RELOAD}" != "none" ]]; then
        rm -f "${BAK}"
    fi

    else
        # LAMP (Apache): panel vhost + optional TLS (self-signed or certbot).
        install -d -m 0755 -o "${WEB_USER}" -g "${WEB_USER}" "${WEB_LOG_DIR}"
        touch "${WEB_LOG_DIR}/lacmp-panel-error.log" "${WEB_LOG_DIR}/lacmp-panel-access.log"
        chown "${WEB_USER}:${WEB_USER}" "${WEB_LOG_DIR}/lacmp-panel-error.log" "${WEB_LOG_DIR}/lacmp-panel-access.log"
        chmod 0640 "${WEB_LOG_DIR}/lacmp-panel-error.log" "${WEB_LOG_DIR}/lacmp-panel-access.log"

        TLS_CRT="" TLS_KEY=""
        if [[ "${ACCESS}" == "public" ]]; then
            install -d -m 0750 -o root -g "${WEB_USER}" /etc/lacmp-panel/tls
            if [[ -n "${PANEL_DOMAIN}" ]]; then
                if command -v apt-get >/dev/null 2>&1; then
                    export DEBIAN_FRONTEND=noninteractive
                    apt-get -y install certbot python3-certbot-apache >/dev/null 2>&1 || true
                elif command -v dnf >/dev/null 2>&1; then
                    dnf -y install certbot python3-certbot-apache >/dev/null 2>&1 || dnf -y install certbot >/dev/null 2>&1 || true
                fi
            fi
            if [[ -n "${PANEL_DOMAIN}" ]] && command -v certbot >/dev/null 2>&1 && [[ "${PANEL_PORT}" == "443" ]]; then
                certbot --apache -d "${PANEL_DOMAIN}" --non-interactive --agree-tos \
                    --email "${LE_EMAIL:-admin@${PANEL_DOMAIN}}" --redirect >/dev/null 2>&1 || true
                TLS_CRT="/etc/letsencrypt/live/${PANEL_DOMAIN}/fullchain.pem"
                TLS_KEY="/etc/letsencrypt/live/${PANEL_DOMAIN}/privkey.pem"
                [[ -f "${TLS_CRT}" ]] || TLS_CRT=""
            fi
            if [[ -z "${TLS_CRT}" ]]; then
                openssl req -x509 -nodes -newkey rsa:2048 -days 825 \
                    -keyout /etc/lacmp-panel/tls/panel.key \
                    -out /etc/lacmp-panel/tls/panel.crt \
                    -subj "/CN=${PANEL_DOMAIN:-${PANEL_IP:-localhost}}" >/dev/null 2>&1
                chmod 0640 /etc/lacmp-panel/tls/panel.key /etc/lacmp-panel/tls/panel.crt
                chown root:"${WEB_USER}" /etc/lacmp-panel/tls/panel.key /etc/lacmp-panel/tls/panel.crt
                TLS_CRT=/etc/lacmp-panel/tls/panel.crt
                TLS_KEY=/etc/lacmp-panel/tls/panel.key
            fi
        fi

        AVAIL="${VHOST_AVAILABLE:-${VHOST_DIR}}"
        install -d -m 0755 "${AVAIL}" "${VHOST_DIR}"
        SNIPPET="${AVAIL}/lacmp-panel.conf"
        LISTEN_CONF=""
        if [[ -d /etc/apache2/conf-available ]]; then
            LISTEN_CONF=/etc/apache2/conf-available/lacmp-panel-listen.conf
        elif [[ -d /etc/httpd/conf.d ]]; then
            LISTEN_CONF=/etc/httpd/conf.d/lacmp-panel-listen.conf
        fi
        BAK=""
        if [[ -e "${SNIPPET}" ]]; then
            BAK="${SNIPPET}.lacmp-bak"
            cp -a "${SNIPPET}" "${BAK}"
        fi
        ALLOW_CSV="$(IFS=','; echo "${ALLOW_IPS[*]+"${ALLOW_IPS[*]}"}")"
        python3 - "${SNIPPET}" "${LISTEN_CONF}" "${PREFIX}" "${PANEL_PORT}" "${ACCESS}" \
            "${PANEL_DOMAIN}" "${PANEL_IP}" "${TLS_CRT}" "${TLS_KEY}" "${WEB_LOG_DIR}" "${ALLOW_CSV}" <<'PY'
import pathlib, sys
snippet, listen, prefix, port, access, domain, ip, crt, key, log_dir, allow_csv = sys.argv[1:12]
allow = [a.strip() for a in allow_csv.split(",") if a.strip()]
web = prefix + "/web/public"
sock = "/run/php/lacmp-panel.sock"
acl = ""
if allow:
    acl = "    <RequireAll>\n        Require ip " + " ".join(allow) + "\n    </RequireAll>\n"
else:
    acl = "    Require all granted\n"
ssl = ""
http = ""
if access == "public" and crt and key:
    # Apache cannot bind HTTP and HTTPS on the same port.
    listen_body = f"Listen {port} https\n"
    ssl = f"""
<VirtualHost *:{port}>
    ServerName {domain or ip or "panel"}
    DocumentRoot {web}
    SSLEngine on
    SSLCertificateFile {crt}
    SSLCertificateKeyFile {key}
    <Directory {web}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
{acl}    </Directory>
    <FilesMatch \\.php$>
        SetHandler "proxy:unix:{sock}|fcgi://localhost"
    </FilesMatch>
    ErrorLog  {log_dir}/lacmp-panel-error.log
    CustomLog {log_dir}/lacmp-panel-access.log combined
</VirtualHost>
"""
else:
    listen_body = f"Listen 127.0.0.1:{port}\n"
    http = f"""# LACMP Panel — generated by install.sh
<VirtualHost 127.0.0.1:{port}>
    ServerName 127.0.0.1
    DocumentRoot {web}
    <Directory {web}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require local
    </Directory>
    <FilesMatch \\.php$>
        SetHandler "proxy:unix:{sock}|fcgi://localhost"
    </FilesMatch>
    ErrorLog  {log_dir}/lacmp-panel-error.log
    CustomLog {log_dir}/lacmp-panel-access.log combined
</VirtualHost>
"""
pathlib.Path(snippet).write_text("# LACMP Panel — generated by install.sh\n" + http + ssl)
if listen:
    pathlib.Path(listen).write_text(listen_body)
PY
        chmod 0644 "${SNIPPET}"
        [[ -n "${LISTEN_CONF}" && -f "${LISTEN_CONF}" ]] && chmod 0644 "${LISTEN_CONF}"
        if ! apache_apply "${SNIPPET}" "${BAK}" "${LISTEN_CONF}"; then
            echo "Apache apply failed after configtest. Existing sites should still be served." >&2
            exit 1
        fi
        if [[ "${CADDY_RELOAD}" != "none" ]]; then
            rm -f "${BAK}"
        fi
    fi
else
    echo "Web-server snippet skipped (--skip-caddy)."
fi

# Persist access settings for uninstall (no secrets).
_ALLOW_CSV="$(IFS=','; echo "${ALLOW_IPS[*]+"${ALLOW_IPS[*]}"}")"
cat > /etc/lacmp-panel/access.env <<EOF
ACCESS_MODE=${ACCESS}
PANEL_PORT=${PANEL_PORT}
PANEL_HAS_DOMAIN=$([ -n "${PANEL_DOMAIN}" ] && echo 1 || echo 0)
PANEL_ALLOW_IPS=${_ALLOW_CSV}
STACK=${STACK}
WEB_SERVICE=${WEB_SERVICE}
EOF
chmod 0640 /etc/lacmp-panel/access.env

# --- firewall + fail2ban (public mode defaults; overridable) ----------------
if [[ "${DO_FAIL2BAN}" == "true" ]]; then
    echo "==> fail2ban jail for panel failed logins"
    if command -v apt-get >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -y install fail2ban >/dev/null
    elif command -v dnf >/dev/null 2>&1; then
        dnf -y install fail2ban >/dev/null || true
    fi

    install -d -m 0755 /etc/fail2ban/filter.d /etc/fail2ban/jail.d
    install -m 0644 "${ROOT}/deploy/fail2ban/filter.d/lacmp-panel.conf" /etc/fail2ban/filter.d/lacmp-panel.conf
    cat > /etc/fail2ban/jail.d/lacmp-panel.conf <<EOF
[lacmp-panel]
enabled  = true
filter   = lacmp-panel
logpath  = /var/log/lacmp-panel/auth-fail.log
backend  = auto
maxretry = 5
findtime = 600
bantime  = 3600
port     = ${PANEL_PORT}
EOF
    systemctl enable --now fail2ban 2>/dev/null || true
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
fi

if [[ "${DO_FIREWALL}" == "true" ]]; then
    echo "==> Firewall rule for panel port ${PANEL_PORT}"
    if command -v apt-get >/dev/null 2>&1 && ! command -v ufw >/dev/null 2>&1; then
        export DEBIAN_FRONTEND=noninteractive
        apt-get -y install ufw >/dev/null || true
    fi
    if command -v ufw >/dev/null 2>&1; then
        ufw_status="$(ufw status 2>/dev/null | head -n1 || true)"
        if echo "${ufw_status}" | grep -qi inactive; then
            if [[ "${ENABLE_UFW}" -eq 1 ]]; then
                ufw allow OpenSSH >/dev/null 2>&1 || ufw allow 22/tcp >/dev/null 2>&1 || true
                echo y | ufw enable >/dev/null 2>&1 || true
            else
                echo "Warning: ufw is inactive. Re-run with --enable-ufw (keeps SSH/22) or open port ${PANEL_PORT} yourself." >&2
            fi
        fi
        if ! echo "$(ufw status 2>/dev/null | head -n1 || true)" | grep -qi inactive; then
            if [[ ${#ALLOW_IPS[@]} -gt 0 ]]; then
                for cidr in "${ALLOW_IPS[@]}"; do
                    ufw allow from "${cidr}" to any port "${PANEL_PORT}" proto tcp comment 'lacmp-panel' >/dev/null || true
                done
            else
                ufw allow "${PANEL_PORT}/tcp" comment 'lacmp-panel' >/dev/null || true
            fi
            echo "UFW_USED=1" >> /etc/lacmp-panel/access.env
        fi
    elif command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --add-port="${PANEL_PORT}/tcp" >/dev/null
        firewall-cmd --reload >/dev/null
        echo "FIREWALLD_USED=1" >> /etc/lacmp-panel/access.env
    else
        echo "Warning: no ufw/firewalld; open TCP ${PANEL_PORT} on the host firewall." >&2
    fi
fi

if [[ "${INSTALL_CADDY_SNIPPET}" -eq 1 && "${CADDY_RELOAD}" != "none" ]]; then
    for _old in ${PREV_PORTS}; do
        if [[ "${_old}" != "${PANEL_PORT}" ]]; then
            echo "==> Removing stale firewall rule for previous panel port ${_old}"
            PANEL_ALLOW_IPS="${PREV_ALLOW_IPS:-}" firewall_delete_port "${_old}"
        fi
    done
fi

# Re-assert traversal vs. secrecy after every rsync/chown.
chmod 0751 "${PREFIX}"
chown root:root "${PREFIX}"
chmod 0750 "${PREFIX}/broker"
chown root:root "${PREFIX}/broker"
chmod -R go-rwx "${PREFIX}/src"
find "${PREFIX}/src" -type d -exec chmod 0750 {} \;
find "${PREFIX}/src" -type f -exec chmod 0640 {} \;
chown -R root:root "${PREFIX}/src"
if [[ -f /etc/lacmp-panel/broker.json ]]; then
    chmod 0600 /etc/lacmp-panel/broker.json
    chown root:root /etc/lacmp-panel/broker.json
fi

echo
echo "Installed."
echo "  Broker:    ${PREFIX}/broker"
echo "  Web:       ${PREFIX}/web"
echo "  Sudoers:   /etc/sudoers.d/lacmp-panel"
echo "  Access:    ${ACCESS}"
echo "  Stack:     ${STACK} (${WEB_SERVICE})"
echo "  Port:      ${PANEL_PORT}"
if [[ "${REQUIRE_TOTP}" == "true" ]]; then
    echo "  TOTP:      required for admin login."
else
    echo "  TOTP:      disabled (admins log in with password only)."
    if [[ "${ACCESS}" == "public" ]]; then
        echo "  Warning:   this panel is internet-facing without TOTP; prefer --require-totp=true"
    fi
fi
if [[ "${DO_FAIL2BAN}" == "true" ]]; then
    echo "  fail2ban:  on (jail lacmp-panel)"
else
    echo "  fail2ban:  off"
fi
if [[ "${DO_FIREWALL}" == "true" ]]; then
    echo "  firewall:  on (TCP ${PANEL_PORT})"
else
    echo "  firewall:  off"
fi
if [[ ${#ALLOW_IPS[@]} -eq 0 ]]; then
    echo "  allowlist: none (global)"
else
    echo "  allowlist: $(IFS=','; echo "${ALLOW_IPS[*]}")"
fi
echo
echo "SSH tunnel (replace ${PANEL_PORT} if you passed a different --port):"
echo "  ssh -L ${PANEL_PORT}:127.0.0.1:${PANEL_PORT} <this-host>"
echo "  then http://127.0.0.1:${PANEL_PORT}"
if [[ "${ACCESS}" == "public" ]]; then
    echo
    if [[ -n "${PANEL_DOMAIN}" ]]; then
        echo "Public HTTPS: https://${PANEL_DOMAIN}:${PANEL_PORT} (trusted cert if issuance succeeded)."
    else
        echo "Public HTTPS: https://${PANEL_IP:-<ip>}:${PANEL_PORT} (self-signed; browser warning expected)."
    fi
else
    echo "The localhost vhost is 127.0.0.1 only. Use --access=public for HTTPS on a network port."
fi
