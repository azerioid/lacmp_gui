#!/usr/bin/env bash
# Reverse install.sh. Never touches existing user sites, Redis,
# MariaDB server, or databases created through the panel.
set -euo pipefail

if [[ ${EUID} -ne 0 ]]; then
    echo "uninstall.sh must run as root" >&2
    exit 1
fi

PREFIX="${PREFIX:-/usr/local/lib/lcmp-panel}"
WEB_USER="${WEB_USER:-}"
PHP_VER="${PHP_VER:-}"
DROP_DB=0

usage() {
    cat <<'EOF'
Usage: uninstall.sh [--drop-db] [--php=8.4]

  --drop-db   Drop lcmp_panel schema/users and /etc/lcmp-panel (secrets)
  --php=X.Y   PHP version used for the FPM pool (default: newest FPM)
EOF
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --drop-db) DROP_DB=1; shift ;;
        --php=*) PHP_VER="${1#*=}"; shift ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; usage >&2; exit 2 ;;
    esac
done

if [[ -z "${WEB_USER}" ]]; then
    if id -u www-data >/dev/null 2>&1; then
        WEB_USER=www-data
    elif id -u apache >/dev/null 2>&1; then
        WEB_USER=apache
    elif id -u caddy >/dev/null 2>&1; then
        WEB_USER=caddy
    else
        WEB_USER=www-data
    fi
fi

if [[ -z "${PHP_VER}" ]]; then
    if ls -d /etc/php/*/fpm >/dev/null 2>&1; then
        PHP_VER="$(ls -d /etc/php/*/fpm | sed 's|/etc/php/||;s|/fpm||' | sort -V | tail -n1)"
    elif command -v php >/dev/null 2>&1; then
        PHP_VER="$(php -v | head -n1 | awk '{print $2}' | cut -d. -f1-2)"
    fi
fi

mariadb_admin() {
    if [[ -f /etc/mysql/debian.cnf ]]; then
        mariadb --defaults-file=/etc/mysql/debian.cnf "$@"
    elif [[ -f /root/.my.cnf ]]; then
        mariadb --defaults-file=/root/.my.cnf "$@"
    else
        mariadb --protocol=socket "$@"
    fi
}

rm -f /etc/sudoers.d/lcmp-panel
if command -v visudo >/dev/null 2>&1; then
    visudo -c >/dev/null || echo "Warning: visudo -c failed after removing panel sudoers." >&2
fi
rm -f /etc/cron.d/lcmp-panel

# fail2ban jail/filter shipped by the panel
rm -f /etc/fail2ban/filter.d/lcmp-panel.conf /etc/fail2ban/jail.d/lcmp-panel.conf
if systemctl is-active fail2ban >/dev/null 2>&1; then
    systemctl reload fail2ban 2>/dev/null || systemctl restart fail2ban 2>/dev/null || true
fi

PANEL_PORT=""
TUNNEL_PORT=""
if [[ -f /etc/lcmp-panel/access.env ]]; then
    # shellcheck disable=SC1091
    . /etc/lcmp-panel/access.env
fi
for _p in ${PANEL_PORT:-} ${TUNNEL_PORT:-}; do
    [[ -n "${_p}" ]] || continue
    if command -v ufw >/dev/null 2>&1; then
        ufw --force delete allow "${_p}/tcp" >/dev/null 2>&1 || true
        if [[ -n "${PANEL_ALLOW_IPS:-}" ]]; then
            IFS=',' read -ra _cidrs <<< "${PANEL_ALLOW_IPS}"
            for _cidr in "${_cidrs[@]}"; do
                _cidr="$(echo "${_cidr}" | tr -d '[:space:]')"
                [[ -n "${_cidr}" ]] || continue
                ufw --force delete allow from "${_cidr}" to any port "${_p}" proto tcp >/dev/null 2>&1 || true
            done
        fi
    fi
    if command -v firewall-cmd >/dev/null 2>&1 && systemctl is-active firewalld >/dev/null 2>&1; then
        firewall-cmd --permanent --remove-port="${_p}/tcp" >/dev/null 2>&1 || true
        firewall-cmd --reload >/dev/null 2>&1 || true
    fi
done
rm -f /etc/tmpfiles.d/lcmp-panel.conf
rm -f /etc/lcmp-panel/access.env

SNIPPET=/etc/caddy/conf.d/lcmp-panel.conf
if [[ -f "${SNIPPET}" ]]; then
    rm -f "${SNIPPET}"
    if command -v caddy >/dev/null 2>&1 && [[ -f /etc/caddy/Caddyfile ]] \
        && /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        sudo -n -u "${WEB_USER}" /usr/bin/caddy reload --config /etc/caddy/Caddyfile --address 127.0.0.1:2019 --force 2>/dev/null \
            || /usr/bin/caddy reload --config /etc/caddy/Caddyfile --address 127.0.0.1:2019 --force 2>/dev/null \
            || true
    else
        if command -v caddy >/dev/null 2>&1; then
            echo "Warning: caddy validate failed after removing the panel snippet." >&2
        fi
    fi
fi

for _ap in /etc/apache2/sites-available/lcmp-panel.conf /etc/httpd/conf.d/vhost/lcmp-panel.conf; do
    if [[ -f "${_ap}" ]]; then
        command -v a2dissite >/dev/null 2>&1 && a2dissite lcmp-panel >/dev/null 2>&1 || true
        rm -f "${_ap}" /etc/apache2/sites-enabled/lcmp-panel.conf
        rm -f /etc/apache2/conf-available/lcmp-panel-listen.conf /etc/apache2/conf-enabled/lcmp-panel-listen.conf
        rm -f /etc/httpd/conf.d/lcmp-panel-listen.conf
        _ctl="$(command -v apache2ctl || command -v apachectl || true)"
        _unit=apache2
        systemctl cat httpd.service >/dev/null 2>&1 && _unit=httpd
        if [[ -n "${_ctl}" ]] && "${_ctl}" -t >/dev/null 2>&1; then
            systemctl reload "${_unit}" 2>/dev/null || true
        else
            echo "Warning: Apache configtest failed after removing the panel vhost." >&2
        fi
    fi
done

rm -f /etc/systemd/system/caddy.service.d/lcmp-panel-reload.conf
if [[ -d /etc/systemd/system/caddy.service.d ]] && [[ -z "$(ls -A /etc/systemd/system/caddy.service.d 2>/dev/null || true)" ]]; then
    rmdir /etc/systemd/system/caddy.service.d 2>/dev/null || true
fi
if [[ -f /etc/lcmp-panel/caddy-admin-managed ]] && [[ -f /etc/caddy/Caddyfile ]]; then
    python3 - /etc/caddy/Caddyfile <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
if not path.is_file():
    raise SystemExit
text = path.read_text()
new, n = re.subn(
    r"^(\s*admin\s+)127\.0\.0\.1:2019(\s*)$",
    r"\1off\2",
    text,
    count=1,
    flags=re.M,
)
new = re.sub(r"\n\s*# lcmp-panel: IPv4 admin[^\n]*", "", new, count=1)
if n:
    path.write_text(new)
    print("Restored Caddy admin off (panel-managed)")
PY
    rm -f /etc/lcmp-panel/caddy-admin-managed
    if command -v caddy >/dev/null 2>&1 && /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        systemctl restart caddy 2>/dev/null || true
    fi
fi
if command -v systemctl >/dev/null 2>&1; then
    systemctl daemon-reload 2>/dev/null || true
fi

if [[ -n "${PHP_VER}" ]]; then
    POOL_DIR=""
    FPM_INI=""
    if [[ -d "/etc/php/${PHP_VER}/fpm/pool.d" ]]; then
        POOL_DIR="/etc/php/${PHP_VER}/fpm/pool.d"
        FPM_INI="/etc/php/${PHP_VER}/fpm/php.ini"
    elif [[ -d /etc/php-fpm.d ]]; then
        POOL_DIR="/etc/php-fpm.d"
        FPM_INI="/etc/php.ini"
    fi
    if [[ -n "${POOL_DIR}" ]]; then
        rm -f "${POOL_DIR}/lcmp-panel.conf"
        python3 - "${POOL_DIR}" <<'PY'
import pathlib, re, sys
pool_dir = pathlib.Path(sys.argv[1])
for path in sorted(pool_dir.glob("*.conf")):
    text = path.read_text()
    new = re.sub(
        r"\n?; --- LCMP-PANEL-LOCKDOWN-BEGIN ---.*?--- LCMP-PANEL-LOCKDOWN-END ---\n?",
        "\n",
        text,
        count=1,
        flags=re.S,
    )
    if new != text:
        path.write_text(new)
PY
    fi
    if [[ -n "${FPM_INI:-}" && -f "${FPM_INI}.lcmp-panel.bak" && -f "${FPM_INI}" ]]; then
        # Re-lock proc_open/proc_get_status on the global FPM ini (public pools).
        python3 - "${FPM_INI}" <<'PY'
import pathlib, re, sys
path = pathlib.Path(sys.argv[1])
text = path.read_text()
need = ["proc_open", "proc_get_status"]
def repl(match: re.Match[str]) -> str:
    funcs = [f.strip() for f in match.group(1).split(",") if f.strip()]
    for extra in need:
        if extra not in funcs:
            funcs.append(extra)
    return "disable_functions = " + ",".join(funcs)
new, n = re.subn(r"^disable_functions\s*=\s*(.*)$", repl, text, count=1, flags=re.M)
if n == 1:
    path.write_text(new)
PY
    fi
    rm -f "/etc/php/${PHP_VER}/fpm/pool.d/lcmp-panel.conf" 2>/dev/null || true
    rm -f /etc/php-fpm.d/lcmp-panel.conf 2>/dev/null || true
    rm -f "/etc/systemd/system/php${PHP_VER}-fpm.service.d/lcmp-panel.conf"
    rm -f /etc/systemd/system/php-fpm.service.d/lcmp-panel.conf
    rmdir "/etc/systemd/system/php${PHP_VER}-fpm.service.d" 2>/dev/null || true
    rmdir /etc/systemd/system/php-fpm.service.d 2>/dev/null || true
    if systemctl cat "php${PHP_VER}-fpm.service" >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl reload "php${PHP_VER}-fpm" 2>/dev/null || true
    elif systemctl cat "php-fpm.service" >/dev/null 2>&1; then
        systemctl daemon-reload
        systemctl reload php-fpm 2>/dev/null || true
    fi
fi

# Preserve APP_KEY (encrypted TOTP/settings) unless we are dropping the DB.
if [[ "${DROP_DB}" -eq 0 && -f "${PREFIX}/web/.env" ]]; then
    install -d -m 0750 -o root -g root /etc/lcmp-panel
    install -m 0600 -o root -g root "${PREFIX}/web/.env" /etc/lcmp-panel/web.env
fi

rm -rf "${PREFIX}"
rm -f /var/log/caddy/access_lcmp-panel.log /var/log/caddy/lcmp-panel.log
rm -f /var/log/apache2/lcmp-panel-error.log /var/log/apache2/lcmp-panel-access.log
rm -f /var/log/httpd/lcmp-panel-error.log /var/log/httpd/lcmp-panel-access.log
rm -rf /var/lib/lcmp-panel
rm -f /var/log/lcmp-panel/auth-fail.log /var/log/lcmp-panel/php-fpm.log

# Legacy location from the first (incorrect) deploy. Only remove if it looks
# like our panel, never a random site under /data/www.
if [[ -f /data/www/lcmp-panel/web/artisan && -f /data/www/lcmp-panel/broker/broker ]]; then
    rm -rf /data/www/lcmp-panel
    echo "Removed leftover /data/www/lcmp-panel (legacy control-plane path)."
fi

if [[ "${DROP_DB}" -eq 1 ]]; then
    mariadb_admin -e "DROP DATABASE IF EXISTS lcmp_panel; DROP USER IF EXISTS 'lcmp_panel'@'localhost'; DROP USER IF EXISTS 'lcmp_panel'@'127.0.0.1'; DROP USER IF EXISTS 'lcmp_panel_admin'@'localhost'; DROP USER IF EXISTS 'lcmp_panel_admin'@'127.0.0.1'; FLUSH PRIVILEGES;"
    rm -rf /etc/lcmp-panel
    echo "Dropped panel DB users and /etc/lcmp-panel."
else
    echo "Kept /etc/lcmp-panel and the lcmp_panel database (pass --drop-db to remove)."
fi

echo "LCMP Panel removed. Existing sites were not touched."
