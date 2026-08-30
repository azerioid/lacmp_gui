<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\CaddyApply;
use LcmpPanel\Broker\CaddyParser;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Validator;

final class VhostAdd
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $domain = Validator::domain($args[0] ?? ($input['domain'] ?? ''));
        $root = Validator::webRoot((string) ($args[1] ?? ($input['root'] ?? '')), $config->wwwRoot, $runtime);
        $type = Validator::vhostType((string) ($args[2] ?? ($input['type'] ?? 'php')));

        $phpVersion = null;
        $upstream = null;
        if ($type === 'php') {
            $phpVersion = Validator::phpVersion((string) ($args[3] ?? ($input['php_version'] ?? '')), $runtime->phpVersions());
        }
        if ($type === 'proxy') {
            $upstream = Validator::localUpstream((string) ($args[3] ?? ($input['upstream'] ?? '')));
        }

        $this->assertNotManaged($domain, $config);

        $confPath = rtrim($config->caddyConfD, '/') . '/' . $domain . '.conf';
        if ($runtime->fileExists($confPath)) {
            throw new BrokerException("A vhost for {$domain} already exists.", 3);
        }

        $this->assertDomainFree($runtime, $config, $domain);

        $contents = $this->render($runtime, $config, $domain, $root, $type, $phpVersion, $upstream);

        if (!$runtime->isDir($root)) {
            $runtime->mkdir($root, 0755);
            $runtime->chown($root, $config->phpUser, $config->phpGroup);
        }

        $tmp = $confPath . '.lcmp-tmp';
        $runtime->writeFile($tmp, $contents, 0644);
        try {
            $runtime->rename($tmp, $confPath);
        } catch (BrokerException $e) {
            $runtime->deleteFile($tmp);
            throw $e;
        }

        $validate = $runtime->exec([$config->caddyBin, 'validate', '--config', $config->caddyfile], null, 20);
        if (!$validate->ok()) {
            $runtime->deleteFile($confPath);
            $detail = trim($validate->stderr . "\n" . $validate->stdout);
            $detail = preg_replace('#/etc/caddy/conf\.d/[^\s:]+#', 'the new vhost file', $detail) ?? $detail;
            throw new BrokerException(
                'Caddy rejected the config: ' . ($detail !== '' ? $detail : 'validation failed') . ' The new vhost was rolled back.',
                1
            );
        }

        try {
            $applied = CaddyApply::run($runtime, $config, 'auto');
        } catch (BrokerException $e) {
            $runtime->deleteFile($confPath);
            try {
                CaddyApply::run($runtime, $config, 'auto');
            } catch (BrokerException) {
            }
            throw new BrokerException(
                'Caddy could not apply the new vhost; the file was rolled back. Existing sites were left serving. ' . $e->getMessage(),
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

    private function assertNotManaged(string $domain, Config $config): void
    {
        $blocked = array_map('strtolower', $config->readonlyVhosts);
        if (in_array($domain, $blocked, true) || $domain === 'default' || $domain === 'lcmp-panel') {
            throw new BrokerException("{$domain} is managed externally and can't be edited.", 3);
        }
    }

    private function assertDomainFree(Runtime $runtime, Config $config, string $domain): void
    {
        foreach ($runtime->glob(rtrim($config->caddyConfD, '/') . '/*.conf') as $file) {
            try {
                $parsed = CaddyParser::parseFile($file, $runtime->readFile($file), $config->readonlyVhosts);
            } catch (\Throwable) {
                continue;
            }
            if ($parsed['readonly'] && (in_array($domain, $parsed['domains'], true) || $parsed['domain'] === $domain)) {
                throw new BrokerException("{$domain} is managed externally and can't be edited.", 3);
            }
            if (in_array($domain, $parsed['domains'], true) || $parsed['domain'] === $domain) {
                throw new BrokerException("A vhost for {$domain} already exists.", 3);
            }
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
        $phpBlock = '';
        $proxyBlock = '';
        if ($type === 'php' && $phpVersion !== null) {
            $sock = $config->phpFpmSocket($phpVersion, $runtime);
            $phpBlock = "    php_fastcgi {$sock}\n";
        }
        if ($type === 'proxy' && $upstream !== null) {
            $proxyBlock = "    reverse_proxy {$upstream}\n";
        }

        $rootBlock = $type === 'proxy' ? '' : "    root * {$root}\n";
        $fileServer = $type === 'proxy' ? '' : "    file_server {\n        index index.html index.php\n    }\n";

        return <<<EOF
{$domain} {
    header {
        Strict-Transport-Security "max-age=31536000; preload"
        X-Content-Type-Options nosniff
        X-Frame-Options SAMEORIGIN
    }
{$rootBlock}    encode gzip zstd
{$phpBlock}{$proxyBlock}{$fileServer}    log {
        output file /var/log/caddy/access_{$domain}.log {
            roll_size 32mb
            roll_keep 3
            roll_keep_for 7d
        }
    }
}

EOF;
    }
}
