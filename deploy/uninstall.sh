#!/usr/bin/env bash
# Reverse install.sh. Never touches projob.az, pong, Redis, MariaDB server,
# or vhosts/databases created through the panel.
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
    if id -u caddy >/dev/null 2>&1; then
        WEB_USER=caddy
    elif id -u www-data >/dev/null 2>&1; then
        WEB_USER=www-data
    else
        WEB_USER=caddy
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

SNIPPET=/etc/caddy/conf.d/lcmp-panel.conf
if [[ -f "${SNIPPET}" ]]; then
    rm -f "${SNIPPET}"
    if /usr/bin/caddy validate --config /etc/caddy/Caddyfile >/dev/null 2>&1; then
        sudo -n -u "${WEB_USER}" /usr/bin/caddy reload --config /etc/caddy/Caddyfile --force 2>/dev/null \
            || true
    else
        echo "Warning: caddy validate failed after removing the panel snippet." >&2
    fi
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
    if systemctl cat "php${PHP_VER}-fpm.service" >/dev/null 2>&1; then
        systemctl reload "php${PHP_VER}-fpm" 2>/dev/null || true
    elif systemctl cat "php-fpm.service" >/dev/null 2>&1; then
        systemctl reload php-fpm 2>/dev/null || true
    fi
fi

# Preserve APP_KEY (encrypted TOTP/settings) unless we are dropping the DB.
if [[ "${DROP_DB}" -eq 0 && -f "${PREFIX}/web/.env" ]]; then
    install -d -m 0750 -o root -g root /etc/lcmp-panel
    install -m 0600 -o root -g root "${PREFIX}/web/.env" /etc/lcmp-panel/web.env
fi

rm -rf "${PREFIX}"
rm -f /var/log/caddy/access_lcmp-panel.log
rm -rf /var/lib/lcmp-panel

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

echo "LCMP Panel removed. Existing sites (including projob.az) were not touched."
