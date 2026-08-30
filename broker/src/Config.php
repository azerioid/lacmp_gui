<?php
declare(strict_types=1);

namespace LcmpPanel\Broker;

final class Config
{
    public string $wwwRoot = '/data/www';
    public string $caddyConfD = '/etc/caddy/conf.d';
    public string $caddyfile = '/etc/caddy/Caddyfile';
    public string $caddyBin = '/usr/bin/caddy';
    public string $auditLog = '/var/log/lcmp-panel/broker-audit.log';
    public string $mysqlSocket = '/run/mysqld/mysqld.sock';
    public string $mysqlUser = 'lcmp_panel_admin';
    public string $mysqlPassword = '';
    public string $phpUser = 'caddy';
    public string $phpGroup = 'caddy';
    public string $mariadbServerCnf = '/etc/mysql/mariadb.conf.d/50-server.cnf';
    public string $panelRoot = '/usr/local/lib/lcmp-panel';
    public string $artisanPath = '/usr/local/lib/lcmp-panel/web/artisan';
    public string $stagingDir = '/var/lib/lcmp-panel/staging';
    public string $cronDPath = '/etc/cron.d/lcmp-panel';
    public string $webUser = 'caddy';

    /** @var list<string> reverse-proxy / operator-protected vhosts (detected at install) */
    public array $readonlyVhosts = [];

    /** @var list<string> */
    public array $protectedDatabases = ['information_schema', 'mysql', 'performance_schema', 'sys', 'lcmp_panel'];

    /** @var array<string,string> log key => path */
    public array $logPaths = [
        'caddy' => '/var/log/caddy/access.log',
        'mariadb' => '/var/log/mysql/error.log',
        'php-fpm' => '/var/log/www-error.log',
        'php-slow' => '/var/log/www-slow.log',
        'panel-audit' => '/var/log/lcmp-panel/broker-audit.log',
        'auth' => '/var/log/auth.log',
        'auth-syslog' => '/var/log/syslog',
    ];

    /** @var list<string> */
    public array $controllableServices = ['caddy', 'mariadb'];

    /** @var list<string> extra systemd units or host:port to observe (default empty) */
    public array $observedServices = [];

    public static function load(string $path, Runtime $runtime): self
    {
        $cfg = new self();
        if (!$runtime->fileExists($path)) {
            return $cfg;
        }
        $raw = $runtime->readFile($path);
        $data = json_decode($raw, true);
        if (!is_array($data)) {
            throw new BrokerException('Broker config is not valid JSON.', 1);
        }
        $cfg->wwwRoot = (string) ($data['paths']['www_root'] ?? $cfg->wwwRoot);
        $cfg->caddyConfD = (string) ($data['paths']['caddy_confd'] ?? $cfg->caddyConfD);
        $cfg->caddyfile = (string) ($data['paths']['caddyfile'] ?? $cfg->caddyfile);
        $cfg->caddyBin = (string) ($data['paths']['caddy_bin'] ?? $cfg->caddyBin);
        $cfg->auditLog = (string) ($data['paths']['audit_log'] ?? $cfg->auditLog);
        $cfg->mariadbServerCnf = (string) ($data['paths']['mariadb_server_cnf'] ?? $cfg->mariadbServerCnf);
        $cfg->panelRoot = (string) ($data['paths']['panel_root'] ?? $cfg->panelRoot);
        $cfg->artisanPath = (string) ($data['paths']['artisan'] ?? $cfg->artisanPath);
        $cfg->stagingDir = (string) ($data['paths']['staging_dir'] ?? $cfg->stagingDir);
        $cfg->cronDPath = (string) ($data['paths']['cron_d'] ?? $cfg->cronDPath);
        $cfg->webUser = (string) ($data['web_user'] ?? $cfg->webUser);
        $cfg->mysqlSocket = (string) ($data['mariadb']['socket'] ?? $cfg->mysqlSocket);
        $cfg->mysqlUser = (string) ($data['mariadb']['user'] ?? $cfg->mysqlUser);
        $cfg->mysqlPassword = (string) ($data['mariadb']['password'] ?? $cfg->mysqlPassword);
        if (isset($data['readonly_vhosts']) && is_array($data['readonly_vhosts'])) {
            $cfg->readonlyVhosts = array_values(array_map('strval', $data['readonly_vhosts']));
        }
        if (isset($data['observed_services']) && is_array($data['observed_services'])) {
            $cfg->observedServices = [];
            foreach ($data['observed_services'] as $entry) {
                $entry = trim((string) $entry);
                if ($entry !== '') {
                    $cfg->observedServices[] = $entry;
                }
            }
        }
        if (isset($data['logs']) && is_array($data['logs'])) {
            $cfg->logPaths = array_merge($cfg->logPaths, $data['logs']);
        }
        return $cfg;
    }

    public function runtimeWithDb(Runtime $runtime): Runtime
    {
        if ($runtime instanceof PosixRuntime) {
            return $runtime->withDatabase($this->mysqlSocket, $this->mysqlUser, $this->mysqlPassword);
        }
        return $runtime;
    }

    public function phpFpmService(string $version): string
    {
        return 'php' . $version . '-fpm';
    }

    public function phpFpmSocket(string $version, ?Runtime $runtime = null): string
    {
        $paths = [
            '/run/php/php-fpm.sock',
            "/run/php/php{$version}-fpm.sock",
            '/run/php-fpm/www.sock',
        ];
        foreach ($paths as $path) {
            if (str_contains($path, 'lcmp-panel')) {
                continue;
            }
            $exists = $runtime !== null ? $runtime->fileExists($path) : is_file($path);
            if ($exists) {
                return 'unix/' . $path;
            }
        }
        return "unix//run/php/php{$version}-fpm.sock";
    }

    public function phpIniPath(string $version): string
    {
        return "/etc/php/{$version}/fpm/php.ini";
    }

    public function controllableServiceList(Runtime $runtime): array
    {
        $list = $this->controllableServices;
        foreach ($runtime->phpVersions() as $ver) {
            $list[] = $this->phpFpmService($ver);
        }
        return array_values(array_unique($list));
    }
}
