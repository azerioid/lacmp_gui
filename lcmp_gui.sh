#!/usr/bin/env bash
#
# lcmp_gui.sh — thin preflight wrapper for LCMP Panel.
# Repo: https://github.com/azerioid/lcmp_gui
#
# REQUIREMENT: teddysun/lcmp must already be installed. This wrapper never
# installs, stops, or reconfigures Caddy/MariaDB/PHP sites.
#
# Usage (as root, from a clone of this repo):
#   chmod +x lcmp_gui.sh
#   ./lcmp_gui.sh --install-caddy-snippet
#
# Flags are forwarded to deploy/install.sh:
#   --install-caddy-snippet   localhost-only Caddy vhost on 127.0.0.1:6969
#   --php=8.4                 PHP version (default: newest installed FPM)
#   --reset-db                rotate panel DB users (destructive)
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

[[ "$(id -u)" -eq 0 ]] || die "This installer must be run as root."

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALLER="${REPO_ROOT}/deploy/install.sh"

if [[ ! -f "${INSTALLER}" ]]; then
    die "deploy/install.sh is missing.

  This looks like a partial clone. Re-clone the full repository:

    git clone https://github.com/azerioid/lcmp_gui.git
    cd lcmp_gui && chmod +x lcmp_gui.sh && ./lcmp_gui.sh --install-caddy-snippet"
fi

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
# LCMP must already be installed — never install or uninstall it from here.
# `command -v` can still report a non-executable path (bind-mount / empty
# file); require -x so a masked or broken stub is treated as missing.
# --------------------------------------------------------------------------
LCMP_BIN="$(command -v lcmp 2>/dev/null || true)"
if [[ -z "${LCMP_BIN}" || ! -x "${LCMP_BIN}" ]]; then
    die "LCMP is not installed (the 'lcmp' command was not found).

  LCMP GUI is only a web front-end for the LCMP stack — install LCMP first:

    ${PKG_MGR} -y install wget git
    git clone https://github.com/teddysun/lcmp.git
    cd lcmp && chmod +x *.sh && ./lcmp.sh

  Then re-run this installer. This script will never install or remove LCMP."
fi

if ! lcmp version >/dev/null 2>&1; then
    warn "'lcmp' is present but 'lcmp version' failed — the install may be broken."
fi

missing=()
command -v caddy >/dev/null 2>&1 || missing+=("caddy")
if ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
    missing+=("mariadb")
fi
if ! ls -d /etc/php/*/fpm >/dev/null 2>&1 && ! ls /etc/php-fpm.d >/dev/null 2>&1; then
    missing+=("php-fpm")
fi
if [[ ${#missing[@]} -gt 0 ]]; then
    die "LCMP command found, but these components are missing: ${missing[*]}.
  Re-run ./lcmp.sh and make sure Caddy, MariaDB and PHP are all installed."
fi
ok "LCMP is installed."

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
if [[ "$PKG_MGR" == "dnf" ]]; then
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

command -v php >/dev/null 2>&1 || die "php CLI is still missing after package install."
command -v python3 >/dev/null 2>&1 || die "python3 is required by the installer."

if ! command -v composer >/dev/null 2>&1; then
    info "Installing Composer to /usr/local/bin/composer..."
    curl -fsSL https://getcomposer.org/installer -o /tmp/composer-setup.php
    php /tmp/composer-setup.php --install-dir=/usr/local/bin --filename=composer >/dev/null
    rm -f /tmp/composer-setup.php
fi
ok "Build tools ready (php $(php -v | head -n1 | awk '{print $2}'), composer $(composer --version 2>/dev/null | awk '{print $3}'))"

chmod +x "${INSTALLER}" "${REPO_ROOT}/deploy/uninstall.sh" "${REPO_ROOT}/broker/broker" 2>/dev/null || true

info "Handing off to deploy/install.sh"
exec "${INSTALLER}" "$@"
