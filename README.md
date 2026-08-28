# LCMP Panel

A web control plane for [teddysun/lcmp](https://github.com/teddysun/lcmp)
(Linux + Caddy + MariaDB + PHP). The `lcmp` CLI stays the source of truth for
the stack; this panel is a tightly scoped, authenticated UI in front of it.

**The panel is control-plane infrastructure, not a user site.** It is installed
under `/usr/local/lib/lcmp-panel/` (never `/data/www`). It binds to
`127.0.0.1:6969` only and is reached over an SSH tunnel.

## Install (documented path)

LCMP must already be installed. This installer will **not** install, stop, or
reconfigure LCMP, projob.az, pong, Redis, or MariaDB.

```bash
# as root, on the LCMP host
git clone https://github.com/azerioid/lcmp_gui.git
cd lcmp_gui
chmod +x lcmp_gui.sh
./lcmp_gui.sh --install-caddy-snippet
```

`lcmp_gui.sh` is a thin preflight wrapper (OS gate, LCMP present, php-cli +
composer). All install logic lives in `deploy/install.sh`. Advanced users may
call that script directly; flags are the same:

| Flag | Meaning |
| --- | --- |
| `--install-caddy-snippet` | Localhost Caddy vhost on `127.0.0.1:6969` |
| `--php=8.4` | PHP version (default: newest installed FPM) |
| `--reset-db` | Rotate panel DB users (destructive) |

Re-run is safe: code is updated, `broker.json` / `APP_KEY` / DB passwords are
**not** rotated unless you pass `--reset-db`.

### Access

```bash
ssh -L 6969:127.0.0.1:6969 you@the-host
# then open http://127.0.0.1:6969
```

First visit is the **setup wizard** (admin email + strong password + TOTP).
2FA is required. There is no `artisan` admin bootstrap.

Uninstall:

```bash
./deploy/uninstall.sh            # keeps the panel DB
./deploy/uninstall.sh --drop-db  # also drops lcmp_panel users/schema
```

Uninstall never deletes vhosts or databases created through the panel, and
never touches projob.az / pong / Redis.

## Privilege separation

Two processes, never one:

1. **Web app** — PHP-FPM pool `lcmp-panel`, user `caddy` (or `www-data`).
   Serves the UI. It has **no** sudo rights except one file.
2. **Broker** — `/usr/local/lib/lcmp-panel/broker`, `root:root` mode `0750`.
   Enumerated actions only. Re-validates every argument. Executes with
   `proc_open($argv)` (no shell). Secrets arrive as JSON on **stdin**, never argv.

sudoers (generated for the real web user + prefix, then `visudo -c`):

```
caddy ALL=(root) NOPASSWD: /usr/local/lib/lcmp-panel/broker
```

MariaDB **admin** credentials live in `/etc/lcmp-panel/broker.json`
(`0600 root:root`). The web tier never reads that file. The panel's own Laravel
database uses a separate `lcmp_panel` user with rights only on `lcmp_panel`.

Layout on disk:

```
/usr/local/lib/lcmp-panel/          0751 root:root   (web user can traverse)
  broker                            0750 root:root   (binary; sudoers target)
  src/                              0750 root:root   (privileged code; web cannot read)
  web/                              0750 caddy:caddy (Laravel app)
/etc/lcmp-panel/broker.json         0600 root:root
```

## Isolation from projob.az

- The panel does **not** edit `/etc/caddy/conf.d/projob.az.conf`.
- `projob.az` / `www.projob.az` are read-only in broker config; any reverse-proxy
  vhost is also flagged read-only.
- Vhost add/delete always runs `caddy validate` before reload, with rollback.
- The panel Caddy snippet listens on **127.0.0.1:6969 only**. Reload uses the
  Caddy admin API (`caddy reload --force` as the Caddy user), not a systemd
  reload that can hang at `JobTimeout=infinity`.
- The panel uses its own FPM pool and its own MariaDB database. It does not
  share RoadRunner, Octane, or the `projob` database.

## Local development (Mac / Herd)

The broker cannot run as root here. Use the fake driver:

```bash
cd web
cp .env.example .env
# APP_ENV=local, APP_DEBUG=true, DB_CONNECTION=sqlite, BROKER_DRIVER=fake
php artisan key:generate
touch database/database.sqlite
php artisan migrate
npm install && npm run dev
```

`BROKER_DRIVER=fake` returns sample data shaped like the real broker (including
a read-only `projob.az` vhost and a MariaDB public-bind warning).

## Tests

```bash
cd web
./vendor/bin/phpunit
```

## Security follow-ups (not auto-fixed)

MariaDB listening on `0.0.0.0:3306` is flagged on the dashboard. The panel
offers a guided bind-to-`127.0.0.1` action with an explicit warning. It does
**not** change this automatically.

## Layout (repo)

```
lcmp_gui.sh           documented entry point (preflight → exec deploy/install.sh)
broker/               privileged CLI + unit tests
web/                  Laravel 12 panel
deploy/install.sh     only place with real install logic
deploy/uninstall.sh
deploy/{caddy,php-fpm,sudoers.d,broker.json.example}
README.md
```
