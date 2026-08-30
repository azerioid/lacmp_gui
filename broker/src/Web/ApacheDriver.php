<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Web;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;

final class ApacheDriver implements WebServerDriver
{
    public function __construct(private readonly Config $config)
    {
    }

    public function stackName(): string
    {
        return 'lamp';
    }

    public function webServiceName(): string
    {
        return $this->config->webService;
    }

    public function listVhosts(Runtime $runtime, Config $config): array
    {
        $sites = [];
        foreach ($this->vhostGlobs($runtime, $config) as $file) {
            try {
                $contents = $runtime->readFile($file);
            } catch (\Throwable) {
                continue;
            }
            $sites[] = ApacheParser::parseFile($file, $contents, $config->readonlyVhosts);
        }
        usort($sites, static fn ($a, $b) => strcmp((string) $a['domain'], (string) $b['domain']));
        return $sites;
    }

    public function addVhost(Runtime $runtime, Config $config, array $spec): array
    {
        $domain = $spec['domain'];
        $root = $spec['root'];
        $type = $spec['type'];
        $phpVersion = $spec['php_version'] ?? null;
        $upstream = $spec['upstream'] ?? null;

        $confPath = $this->siteAvailablePath($config, $domain);
        if ($runtime->fileExists($confPath)) {
            throw new BrokerException("A vhost for {$domain} already exists.", 3);
        }
        foreach ($this->listVhosts($runtime, $config) as $parsed) {
            if (($parsed['domain'] ?? '') === $domain || in_array($domain, $parsed['domains'] ?? [], true)) {
                throw new BrokerException(
                    !empty($parsed['readonly'])
                        ? "{$domain} is managed externally and can't be edited."
                        : "A vhost for {$domain} already exists.",
                    3
                );
            }
        }

        $contents = $this->render($runtime, $config, $domain, $root, $type, $phpVersion, $upstream);
        if (!$runtime->isDir($root)) {
            $runtime->mkdir($root, 0755);
            $runtime->chown($root, $config->phpUser, $config->phpGroup);
        }
        $this->ensureLogDir($runtime, $config);

        $dir = dirname($confPath);
        if (!$runtime->isDir($dir)) {
            $runtime->mkdir($dir, 0755);
        }
        $tmp = $confPath . '.lcmp-tmp';
        $runtime->writeFile($tmp, $contents, 0644);
        try {
            $runtime->rename($tmp, $confPath);
        } catch (BrokerException $e) {
            $runtime->deleteFile($tmp);
            throw $e;
        }

        $enabled = false;
        try {
            $this->enableSite($runtime, $config, $domain, $confPath);
            $enabled = true;
            $this->validate($runtime, $config);
            $applied = $this->reload($runtime, $config, 'auto');
        } catch (BrokerException $e) {
            if ($enabled) {
                $this->disableSite($runtime, $config, $domain);
            }
            $runtime->deleteFile($confPath);
            try {
                $this->reload($runtime, $config, 'auto');
            } catch (BrokerException) {
            }
            throw new BrokerException(
                'Apache rejected the config. The new vhost was rolled back. Existing sites were left serving. ' . $e->getMessage(),
                1
            );
        }

        return [
            'domain' => $domain,
            'root' => $root,
            'type' => $type,
            'php_version' => $phpVersion,
            'upstream' => $upstream,
            'source' => $confPath,
            'apply' => $applied,
        ];
    }

    public function removeVhost(Runtime $runtime, Config $config, string $domain): array
    {
        $confPath = $this->existingPath($runtime, $config, $domain);
        if ($confPath === null) {
            throw new BrokerException('Vhost config does not exist.', 3);
        }
        $contents = $runtime->readFile($confPath);
        $parsed = ApacheParser::parseFile($confPath, $contents, $config->readonlyVhosts);
        if ($parsed['readonly']) {
            throw new BrokerException('This vhost is managed externally and cannot be deleted by the panel.', 3);
        }

        $this->disableSite($runtime, $config, $domain);
        $runtime->deleteFile($confPath);

        try {
            $this->validate($runtime, $config);
            $applied = $this->reload($runtime, $config, 'auto');
        } catch (BrokerException $e) {
            $runtime->writeFile($confPath, $contents, 0644);
            $this->enableSite($runtime, $config, $domain, $confPath);
            try {
                $this->reload($runtime, $config, 'auto');
            } catch (BrokerException) {
            }
            throw new BrokerException(
                'Apache would fail without this vhost; the file was restored. ' . $e->getMessage(),
                1
            );
        }

        return [
            'domain' => $domain,
            'deleted' => $confPath,
            'web_root_preserved' => $parsed['root'],
            'apply' => $applied,
        ];
    }

    public function reload(Runtime $runtime, Config $config, string $mode = 'auto', array $expectPorts = []): array
    {
        $this->validate($runtime, $config);
        $unit = $config->webService;
        fwrite(STDERR, "==> Applying via systemctl reload {$unit}\n");
        $result = $runtime->exec(['/usr/bin/systemctl', 'reload', $unit], null, 60);
        if (!$result->ok()) {
            if ($mode === 'restart' || $mode === 'auto') {
                fwrite(STDERR, "==> Applying via systemctl restart {$unit} (brief connection drop)\n");
                $result = $runtime->exec(['/usr/bin/systemctl', 'restart', $unit], null, 60);
                if ($result->ok()) {
                    $this->assertActive($runtime, $unit);
                    return ['path' => 'restart', 'address' => '', 'admin_spec' => 'n/a', 'admin_enabled' => false];
                }
            }
            $detail = trim($result->stderr . "\n" . $result->stdout);
            throw new BrokerException(
                "systemctl reload {$unit} failed" . ($detail !== '' ? ': ' . $detail : '.'),
                1
            );
        }
        $this->assertActive($runtime, $unit);
        fwrite(STDERR, "==> Apache apply path: systemctl (unit {$unit})\n");
        return ['path' => 'systemctl', 'address' => '', 'admin_spec' => 'n/a', 'admin_enabled' => false];
    }

    public function backupPaths(Config $config): array
    {
        $paths = [$config->vhostDir];
        if ($config->vhostAvailableDir !== '' && $config->vhostAvailableDir !== $config->vhostDir) {
            $paths[] = $config->vhostAvailableDir;
        }
        return $paths;
    }

    public function version(Runtime $runtime, Config $config): array
    {
        $ctl = $this->apacheCtl($runtime, $config);
        $r = $runtime->exec(array_merge($ctl, ['-v']));
        $raw = trim($r->stdout !== '' ? $r->stdout : $r->stderr);
        $version = $raw;
        if (preg_match('/Apache\/([0-9.]+)/', $raw, $m)) {
            $version = $m[1];
        }
        return [
            'version' => $version,
            'raw' => explode("\n", $raw)[0] ?? $raw,
            'service' => $config->webService,
            'label' => 'Apache',
            'stack' => 'lamp',
        ];
    }

    private function validate(Runtime $runtime, Config $config): void
    {
        $ctl = $this->apacheCtl($runtime, $config);
        $result = $runtime->exec(array_merge($ctl, ['-t']), null, 20);
        if (!$result->ok()) {
            $detail = trim($result->stderr . "\n" . $result->stdout);
            throw new BrokerException(
                'Apache rejected the config: ' . ($detail !== '' ? $detail : 'configtest failed'),
                1
            );
        }
    }

    /** @return list<string> */
    private function apacheCtl(Runtime $runtime, Config $config): array
    {
        foreach ([$config->apacheCtl, '/usr/sbin/apache2ctl', '/usr/sbin/apachectl', '/usr/sbin/httpd'] as $bin) {
            if ($runtime->fileExists($bin)) {
                return [$bin];
            }
        }
        return ['/usr/sbin/apachectl'];
    }

    private function debianLayout(Runtime $runtime, Config $config): bool
    {
        return $runtime->isDir($config->vhostAvailableDir) || $runtime->isDir('/etc/apache2/sites-available');
    }

    private function siteAvailablePath(Config $config, string $domain): string
    {
        if ($config->vhostAvailableDir !== '') {
            return rtrim($config->vhostAvailableDir, '/') . '/' . $domain . '.conf';
        }
        return rtrim($config->vhostDir, '/') . '/' . $domain . '.conf';
    }

    private function existingPath(Runtime $runtime, Config $config, string $domain): ?string
    {
        foreach ($this->vhostGlobs($runtime, $config) as $file) {
            if (basename($file, '.conf') === $domain) {
                return $file;
            }
        }
        $candidate = $this->siteAvailablePath($config, $domain);
        return $runtime->fileExists($candidate) ? $candidate : null;
    }

    /** @return list<string> */
    private function vhostGlobs(Runtime $runtime, Config $config): array
    {
        $files = $runtime->glob(rtrim($config->vhostDir, '/') . '/*.conf');
        if ($config->vhostAvailableDir !== '' && $config->vhostAvailableDir !== $config->vhostDir) {
            $files = array_merge($files, $runtime->glob(rtrim($config->vhostAvailableDir, '/') . '/*.conf'));
        }
        return array_values(array_unique($files));
    }

    private function enableSite(Runtime $runtime, Config $config, string $domain, string $confPath): void
    {
        if ($this->debianLayout($runtime, $config) && $runtime->fileExists('/usr/sbin/a2ensite')) {
            $r = $runtime->exec(['/usr/sbin/a2ensite', $domain], null, 15);
            if (!$r->ok()) {
                throw new BrokerException(trim($r->stderr . "\n" . $r->stdout) ?: 'a2ensite failed.', 1);
            }
            return;
        }
        $enabled = rtrim($config->vhostDir, '/') . '/' . $domain . '.conf';
        if ($enabled !== $confPath && !$runtime->fileExists($enabled)) {
            $runtime->writeFile($enabled, $runtime->readFile($confPath), 0644);
        }
    }

    private function disableSite(Runtime $runtime, Config $config, string $domain): void
    {
        if ($this->debianLayout($runtime, $config) && $runtime->fileExists('/usr/sbin/a2dissite')) {
            $runtime->exec(['/usr/sbin/a2dissite', $domain], null, 15);
        }
    }

    private function assertActive(Runtime $runtime, string $unit): void
    {
        $active = $runtime->exec(['/usr/bin/systemctl', 'is-active', $unit]);
        if (trim($active->stdout) !== 'active' && !$active->ok()) {
            throw new BrokerException("Apache is not active after apply (systemctl is-active {$unit} failed).", 1);
        }
    }

    private function ensureLogDir(Runtime $runtime, Config $config): void
    {
        $dir = $config->webLogDir;
        if (!$runtime->isDir($dir)) {
            $runtime->mkdir($dir, 0755);
            $runtime->chown($dir, $config->webUser, $config->webUser);
        }
    }

    private function render(
        Runtime $runtime,
        Config $config,
        string $domain,
        string $root,
        string $type,
        ?string $phpVersion,
        ?string $upstream,
    ): string {
        $logs = $config->webLogDir;
        $phpBlock = '';
        $proxyBlock = '';
        $dirBlock = '';
        if ($type === 'php' && $phpVersion !== null) {
            $sock = $config->phpFpmUnixPath($phpVersion, $runtime);
            $phpBlock = <<<PHP
    <FilesMatch \\.php\$>
        SetHandler "proxy:unix:{$sock}|fcgi://localhost"
    </FilesMatch>

PHP;
        }
        if ($type === 'proxy' && $upstream !== null) {
            $proxyBlock = "    ProxyPreserveHost On\n    ProxyPass / http://{$upstream}/\n    ProxyPassReverse / http://{$upstream}/\n";
        }
        if ($type !== 'proxy') {
            $dirBlock = <<<DIR
    DocumentRoot {$root}
    <Directory {$root}>
        Options -Indexes +FollowSymLinks
        AllowOverride All
        Require all granted
    </Directory>

DIR;
        }

        return <<<EOF
<VirtualHost *:80>
    ServerName {$domain}
{$dirBlock}{$phpBlock}{$proxyBlock}    ErrorLog  {$logs}/{$domain}-error.log
    CustomLog {$logs}/{$domain}-access.log combined
</VirtualHost>

EOF;
    }
}
