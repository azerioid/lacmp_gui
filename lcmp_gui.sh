#!/usr/bin/env bash
#
# lcmp_gui.sh — thin preflight wrapper for LCMP Panel.
# Repo: https://github.com/azerioid/lcmp_gui
#
# REQUIREMENT: teddysun/lcmp (Caddy) or teddysun/lamp (Apache) must already be installed.
# This wrapper never installs, stops, or reconfigures the stack's sites.
#
# Usage (as root, from a clone of this repo):
#   chmod +x lcmp_gui.sh
#   ./lcmp_gui.sh
#
# Flags are forwarded to deploy/install.sh. Run ./lcmp_gui.sh --help
#
set -euo pipefail

if [[ -t 1 ]]; then
    C_RED=$'\e[31m'; C_GRN=$'\e[32m'; C_YLW=$'\e[33m'; C_CYN=$'\e[36m'; C_RST=$'\e[0m'
else
    C_RED=""; C_GRN=""; C_YLW=""; C_CYN=""; C_RST=""
fi
info()  { echo "${C_CYN}[*]${C_RST} $*"; }
ok()    { echo "${C_GRN}[OK]${C_RST} $*"; }
warn()  { echo "${C_YLW}[!]${C_RST} $*"; }
die()   { echo "${C_RED}[ERROR]${C_RST} $*" >&2; exit 1; }

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${REPO_ROOT}/deploy/install.sh"

if [[ ! -f "${INSTALLER}" ]]; then
    echo "deploy/install.sh is missing.

  This looks like a partial clone. Re-clone the full repository:

    git clone https://github.com/azerioid/lcmp_gui.git
    cd lcmp_gui && chmod +x lcmp_gui.sh && ./lcmp_gui.sh" >&2
    exit 1
fi

for _arg in "$@"; do
    case "${_arg}" in
        -h|--help)
            exec bash "${INSTALLER}" --help
            ;;
    esac
done

[[ "$(id -u)" -eq 0 ]] || die "This installer must be run as root."

DRY_RUN=0
for _arg in "$@"; do
    case "${_arg}" in
        --dry-run) DRY_RUN=1 ;;
    esac
done

# --------------------------------------------------------------------------
# OS gate
# --------------------------------------------------------------------------
[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release — unsupported system."
# shellcheck disable=SC1091
. /etc/os-release
OS_ID="${ID:-unknown}"
OS_VER="${VERSION_ID:-0}"
OS_MAJOR="${OS_VER%%.*}"

PKG_MGR=""
case "$OS_ID" in
    almalinux|rocky|centos|rhel|ol)
        case "$OS_MAJOR" in
            8|9|10) PKG_MGR="dnf" ;;
            *) die "Enterprise Linux ${OS_VER} is not supported (need 8/9/10)." ;;
        esac
        ;;
    debian)
        case "$OS_MAJOR" in
            11|12|13) PKG_MGR="apt-get" ;;
            *) die "Debian ${OS_VER} is not supported (need 11/12/13)." ;;
        esac
        ;;
    ubuntu)
        case "$OS_VER" in
            22.04|24.04) PKG_MGR="apt-get" ;;
            *) die "Ubuntu ${OS_VER} is not supported (need 22.04/24.04)." ;;
        esac
        ;;
    *)
        die "Unsupported distribution: ${OS_ID} ${OS_VER}."
        ;;
esac
ok "Detected supported OS: ${PRETTY_NAME:-$OS_ID $OS_VER} (package manager: ${PKG_MGR})"

# --------------------------------------------------------------------------
# LCMP (Caddy) or LAMP (Apache) must already be installed.
# --------------------------------------------------------------------------
HAS_LCMP=0
HAS_LAMP=0
LCMP_BIN="$(command -v lcmp 2>/dev/null || true)"
LAMP_BIN="$(command -v lamp 2>/dev/null || true)"
[[ -n "${LCMP_BIN}" && -x "${LCMP_BIN}" ]] && HAS_LCMP=1
[[ -n "${LAMP_BIN}" && -x "${LAMP_BIN}" ]] && HAS_LAMP=1

STACK_ARG=""
for arg in "$@"; do
    case "$arg" in
        --stack=*) STACK_ARG="${arg#--stack=}" ;;
    esac
done

if [[ "${HAS_LCMP}" -eq 0 && "${HAS_LAMP}" -eq 0 ]]; then
    die "Neither LCMP nor LAMP is installed (no 'lcmp' or 'lamp' command).

  This panel is a web front-end for teddysun LCMP or LAMP — install one first:

    ${PKG_MGR} -y install wget git
    git clone https://github.com/teddysun/lcmp.git   # Caddy stack
    cd lcmp && chmod +x *.sh && ./lcmp.sh

    # or:
    git clone https://github.com/teddysun/lamp.git   # Apache stack
    cd lamp && chmod 755 *.sh && ./lamp.sh

  Then re-run this installer. This script will never install or remove the stack."
fi

if [[ "${HAS_LCMP}" -eq 1 ]] && ! lcmp version >/dev/null 2>&1; then
    warn "'lcmp' is present but 'lcmp version' failed — the install may be broken."
fi
if [[ "${HAS_LAMP}" -eq 1 ]] && ! lamp version >/dev/null 2>&1; then
    warn "'lamp' is present but 'lamp version' failed — the install may be broken."
fi

missing=()
if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
    missing+=("mariadb")
fi
if ! ls -d /etc/php/*/fpm >/dev/null 2>&1 && ! ls /etc/php-fpm.d >/dev/null 2>&1; then
    missing+=("php-fpm")
fi
WEB_OK=0
command -v caddy >/dev/null 2>&1 && WEB_OK=1
command -v apache2 >/dev/null 2>&1 && WEB_OK=1
command -v apachectl >/dev/null 2>&1 && WEB_OK=1
command -v httpd >/dev/null 2>&1 && WEB_OK=1
command -v apache2ctl >/dev/null 2>&1 && WEB_OK=1
[[ "${WEB_OK}" -eq 1 ]] || missing+=("web-server (caddy or apache)")
if [[ ${#missing[@]} -gt 0 ]]; then
    die "Stack command found, but these components are missing: ${missing[*]}.
  Re-run ./lcmp.sh or ./lamp.sh and make sure the web server, MariaDB and PHP are installed."
fi
if [[ "${HAS_LCMP}" -eq 1 && "${HAS_LAMP}" -eq 1 ]]; then
    ok "Both LCMP and LAMP commands are present; the installer will pick the web server bound to :80/:443 (or --stack=)."
elif [[ "${HAS_LCMP}" -eq 1 ]]; then
    ok "LCMP (Caddy) is installed."
else
    ok "LAMP (Apache) is installed."
fi

# --------------------------------------------------------------------------
# PHP version: newest installed FPM, unless the caller passed --php=
# --------------------------------------------------------------------------
PHP_VER=""
for arg in "$@"; do
    case "$arg" in
        --php=*) PHP_VER="${arg#--php=}" ;;
    esac
done
if [[ -z "${PHP_VER}" ]]; then
    if ls -d /etc/php/*/fpm >/dev/null 2>&1; then
        PHP_VER="$(ls -d /etc/php/*/fpm | sed 's|/etc/php/||;s|/fpm||' | sort -V | tail -n1)"
    elif command -v php >/dev/null 2>&1; then
        PHP_VER="$(php -v | head -n1 | awk '{print $2}' | cut -d. -f1-2)"
    fi
fi
[[ -n "${PHP_VER}" ]] || die "Cannot detect PHP version. Pass --php=8.4"

# --------------------------------------------------------------------------
# Build tools the worker (install.sh) assumes exist
# --------------------------------------------------------------------------
info "Ensuring git, unzip, curl, python3, php${PHP_VER}-cli, composer..."
if [[ "${DRY_RUN}" -eq 1 ]]; then
    warn "dry-run: skipping package installs"
elif [[ "$PKG_MGR" == "dnf" ]]; then
    dnf -y install git unzip curl python3 rsync sudo \
        "php-cli" "php-xml" "php-mbstring" "php-mysqlnd" "php-json"
else
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -qq
    apt-get -y install git unzip curl python3 rsync sudo \
        "php${PHP_VER}-cli" "php${PHP_VER}-xml" "php${PHP_VER}-mbstring" \
        "php${PHP_VER}-curl" "php${PHP_VER}-mysql" "php${PHP_VER}-zip" \
        "php${PHP_VER}-bcmath"
fi

if [[ "${DRY_RUN}" -eq 0 ]]; then
    command -v php >/dev/null 2>&1 || die "php CLI is still missing after package install."
    command -v python3 >/dev/null 2>&1 || die "python3 is required by the installer."

    if ! command -v composer >/dev/null 2>&1; then
        info "Installing Composer to /usr/local/bin/composer..."
        curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
        php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
        rm -f /tmp/composer-setup.php
    fi
    ok "Build tools ready (php $(php -v | head -n1 | awk '{print $2}'), composer $(composer --version 2>/dev/null | awk '{print $3}'))"
else
    ok "dry-run: wrapper preflight complete (no packages installed)"
fi

chmod +x "${INSTALLER}" "${REPO_ROOT}/deploy/uninstall.sh" "${REPO_ROOT}/broker/broker" 2>/dev/null || true

info "Handing off to deploy/install.sh"
exec "${INSTALLER}" "$@"
