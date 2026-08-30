# LCMP Panel

A web control plane for [teddysun/lcmp](https://github.com/teddysun/lcmp)
(Linux + Caddy + MariaDB + PHP). The `lcmp` CLI stays the source of truth;
this panel is a scoped, authenticated UI in front of it.

The panel is **control-plane infrastructure**, not a user site. It installs
under `/usr/local/lib/lcmp-panel/` (never the LCMP www root).

## Prerequisites

- A supported OS: Ubuntu 22.04/24.04, Debian 11–13, or EL 8/9/10
- **LCMP already installed** (`lcmp` on PATH). This installer will not install,
  stop, or reconfigure LCMP, Caddy vhosts, MariaDB data, Redis, or your sites.

## Install

```bash
# as root, on the LCMP host
git clone https://github.com/azerioid/lcmp_gui.git
cd lcmp_gui
chmod +x lcmp_gui.sh
./lcmp_gui.sh
```

With no flags, a TTY prompts for access mode (default **tunnel**) and listen
port (default **3169**). Non-interactive runs default to tunnel on 3169.
Override with `--port=NNNN`.

`lcmp_gui.sh` is a thin preflight (OS gate, LCMP present, php-cli + composer).
All install logic is in `deploy/install.sh`.

### Access modes

| Mode | How you reach it | TLS | When to use |
| --- | --- | --- | --- |
| **tunnel** (default) | `ssh -L 3169:127.0.0.1:3169 user@host` then `http://127.0.0.1:3169` (replace `3169` if you passed `--port`) | localhost HTTP only | Safest. No public listener. |
| **public + domain** | `https://panel.example.com:PORT` | Let's Encrypt | Recommended if you have a DNS name. |
| **public + IP** | `https://<ip>:PORT` | Caddy `tls internal` (self-signed) | No DNS. Browser shows an untrusted-cert warning. Traffic is still encrypted. |

Public mode **never** serves the panel over plaintext HTTP on a public interface.
By default it also enables **TOTP**, a **fail2ban** jail, and a firewall rule
(`--require-totp` / `--fail2ban` / `--firewall` can turn those off).

```bash
# Tunnel only (explicit; default port 3169)
./lcmp_gui.sh --access=tunnel

# Custom port
./lcmp_gui.sh --port=4444

# Public IP mode (self-signed HTTPS)
./lcmp_gui.sh --access=public --port=3169 --ip=203.0.113.10

# Non-interactive (automation — must pass --domain= or --ip= in public mode)
./lcmp_gui.sh --non-interactive --access=public --ip=203.0.113.10 --port=3169 --enable-ufw

# Caddy apply: auto (default) probes the admin API, then systemctl reload, then restart
./lcmp_gui.sh --caddy-reload=auto
./lcmp_gui.sh --caddy-reload=none   # write+validate only; print the apply commands

# Public domain mode (Let's Encrypt)
./lcmp_gui.sh --access=public --domain=panel.example.com --port=3169 --le-email=you@example.com
```

`./lcmp_gui.sh --help` lists every flag and default.

If ufw is installed but inactive, pass `--enable-ufw` so the installer can
enable it **after** allowing SSH/22.

The SSH-tunnel path on `127.0.0.1:<port>` (default 3169) stays available even after public mode. Replace 3169 with your `--port` if you changed it.

| Flag | Meaning |
| --- | --- |
| `--access=tunnel\|public` | Access mode (default: tunnel) |
| `--domain=` / `--ip=` | Public HTTPS identity |
| `--port=` | Panel listen port (default 3169; not 80/443). Used for the SSH tunnel bind and for public HTTPS. |
| `--allow-ip=` | Comma-list or repeatable CIDR allowlist |
| `--email=` / `--le-email=` | ACME email (domain mode) |
| `--caddy-reload=` | `auto` (default), `api`, `systemctl`, `restart`, `none` |
| `--require-totp=` | `true`/`false` (default true) |
| `--firewall=` / `--fail2ban=` | default true in public mode |
| `--php=8.4` | PHP version (default: newest FPM) |
| `--prefix=` / `--web-user=` | layout overrides |
| `--non-interactive` | no prompts; public requires `--domain` or `--ip` |
| `--dry-run` | print the plan; change nothing |
| `--reset-db` | Rotate panel DB users (destructive) |
| `--skip-caddy` | Do not write Caddy snippets |
| `--enable-ufw` | Enable inactive ufw, keeping SSH |
| `--readonly-vhost=` | Extra read-only vhost name |

Re-run is safe: code is updated; `broker.json` / `APP_KEY` / DB passwords are
**not** rotated unless `--reset-db`. Reverse-proxy vhosts are re-detected and
marked read-only.

### First run

Open the panel and complete the **setup wizard** (admin email + strong password
+ TOTP). 2FA is required. There is no `artisan` admin bootstrap.

Uninstall:

```bash
./deploy/uninstall.sh            # keeps the panel DB
./deploy/uninstall.sh --drop-db  # also drops lcmp_panel users/schema
```

Uninstall removes the panel prefix, FPM pool, sudoers, Caddy snippet, cron,
fail2ban jail, and the panel firewall rule. It never deletes vhosts or
databases created through the panel.

## Privilege separation

1. **Web app** — PHP-FPM pool `lcmp-panel`, user `caddy` or `www-data`.
2. **Broker** — `/usr/local/lib/lcmp-panel/broker`, `root:root` mode `0750`.
   Enumerated actions, argv arrays (no shell). Secrets on stdin JSON.

sudoers (generated for the real web user + prefix):

```
caddy ALL=(root) NOPASSWD: /usr/local/lib/lcmp-panel/broker
```

MariaDB **admin** credentials live in `/etc/lcmp-panel/broker.json`
(`0600 root:root`). The web `.env` only has the limited `lcmp_panel` app user.

Layout:

```
/usr/local/lib/lcmp-panel/          0751 root:root
  broker                            0750 root:root
  src/                              0750 root:root
  web/                              0750 web-user
/etc/lcmp-panel/broker.json         0600 root:root
```

PHP-FPM on Debian/Ubuntu uses `ProtectSystem=full`. The installer adds a
systemd drop-in so FPM can write panel storage under `/usr/local/lib`.

## Isolation from existing sites

- The installer does not edit other files in `/etc/caddy/conf.d/`.
- Any Caddy vhost that `reverse_proxy`s a local backend is marked **read-only**
  (detected at install). Add more with `--readonly-vhost=`.
- Caddy changes always `caddy validate` then `caddy reload --force` as the
  Caddy user (not a systemd reload). Validate failure rolls the snippet back.
- Dedicated FPM pool and MariaDB database.

## Local development (Mac / Herd)

```bash
cd web
cp .env.example .env
# APP_ENV=local, APP_DEBUG=true, DB_CONNECTION=sqlite, BROKER_DRIVER=fake
php artisan key:generate
touch database/database.sqlite
php artisan migrate
npm install && npm run dev
```

`BROKER_DRIVER=fake` returns sample data shaped like the real broker.

## Tests

```bash
cd web
./vendor/bin/phpunit
```

## Troubleshooting

- **Caddy admin API connection refused (`dial tcp [::1]:2019`):** the installer
  now probes `127.0.0.1` first and falls back to `systemctl reload` then
  `systemctl restart`. Re-run the installer; check the log line
  `Caddy apply strategy` / `Applying via`.
- **HTTP 500 on first request:** FPM could not write under `/usr/local/lib`
  (`ProtectSystem=full`). Re-run the installer (it writes the systemd drop-in
  and restarts FPM) or check `systemctl show phpX.Y-fpm -p ReadWritePaths`.
- **Caddy validate failed:** the previous panel snippet is restored; other
  vhosts are unchanged.
- **Public IP mode cert warning:** expected (`tls internal`). Use domain mode
  for a trusted certificate.
- **ufw inactive:** pass `--enable-ufw` or open the port yourself.

## Security follow-ups (not auto-fixed)

If MariaDB listens on `0.0.0.0:3306`, the dashboard flags it. Bind-to-localhost
is an explicit click in the UI, never automatic.

## Layout (repo)

```
lcmp_gui.sh           documented entry point
broker/               privileged CLI + unit tests
web/                  Laravel 12 panel
deploy/install.sh     only place with real install logic
deploy/uninstall.sh
deploy/fail2ban/      filter + jail (no secrets)
deploy/{caddy,php-fpm,sudoers.d,broker.json.example}
README.md
```
