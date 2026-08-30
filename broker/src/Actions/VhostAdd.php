<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\CaddyParser;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Systemd;
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

        $confPath = rtrim($config->caddyConfD, '/') . '/' . $domain . '.conf';
        if ($runtime->fileExists($confPath)) {
            throw new BrokerException('A vhost config already exists for this domain.', 3);
        }

        $this->assertDomainFree($runtime, $config, $domain);

        $contents = $this->render($config, $domain, $root, $type, $phpVersion, $upstream);

        if (!$runtime->isDir($root)) {
            $runtime->mkdir($root, 0755);
            $runtime->chown($root, $config->phpUser, $config->phpGroup);
        }

        $runtime->writeFile($confPath, $contents, 0644);

        $validate = $runtime->exec([$config->caddyBin, 'validate', '--config', $config->caddyfile], null, 20);
        if (!$validate->ok()) {
            $runtime->deleteFile($confPath);
            throw new BrokerException(
                'Caddy rejected the new vhost; the file was rolled back. ' . trim($validate->stderr . "\n" . $validate->stdout),
                1
            );
        }

        try {
            Systemd::applyCaddy($runtime);
        } catch (BrokerException $e) {
            $runtime->deleteFile($confPath);
            try {
                Systemd::applyCaddy($runtime);
            } catch (BrokerException) {
                // best-effort restore of previous listener set
            }
            throw new BrokerException(
                'Caddy reload/restart failed after adding the vhost; the file was rolled back. ' . $e->getMessage(),
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
        ];
    }

    private function assertDomainFree(Runtime $runtime, Config $config, string $domain): void
    {
        foreach ($runtime->glob(rtrim($config->caddyConfD, '/') . '/*.conf') as $file) {
            try {
                $parsed = CaddyParser::parseFile($file, $runtime->readFile($file), $config->readonlyVhosts);
            } catch (\Throwable) {
                continue;
            }
            if (in_array($domain, $parsed['domains'], true) || $parsed['domain'] === $domain) {
                throw new BrokerException('Domain is already present in ' . $file, 3);
            }
        }
    }

    private function render(
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
