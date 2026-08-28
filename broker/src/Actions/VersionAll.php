<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;

final class VersionAll
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        return [
            'caddy' => self::caddy($runtime, $config),
            'mariadb' => self::mariadb($runtime),
            'php' => self::php($runtime),
        ];
    }

    private static function caddy(Runtime $runtime, Config $config): array
    {
        $bin = $runtime->fileExists($config->caddyBin) ? $config->caddyBin : '/usr/bin/caddy';
        $r = $runtime->exec([$bin, 'version']);
        $line = trim(explode("\n", $r->stdout)[0] ?? '');
        $version = $line;
        if (preg_match('/v?(\d+\.\d+\.\d+\S*)/', $line, $m)) {
            $version = $m[1];
        }
        return ['version' => $version, 'raw' => $line];
    }

    private static function mariadb(Runtime $runtime): array
    {
        $bin = $runtime->fileExists('/usr/bin/mariadb') ? '/usr/bin/mariadb' : '/usr/bin/mysql';
        $r = $runtime->exec([$bin, '--version']);
        $raw = trim($r->stdout);
        $version = $raw;
        if (preg_match('/(?:mariadb|mysql).*?\s([0-9]+\.[0-9]+\.[0-9]+)/i', $raw, $m)) {
            $version = $m[1];
        } elseif (preg_match('/Distrib ([0-9.]+)/', $raw, $m)) {
            $version = $m[1];
        }
        return ['version' => $version, 'raw' => $raw];
    }

    private static function php(Runtime $runtime): array
    {
        $r = $runtime->exec(['/usr/bin/php', '-v']);
        $raw = trim($r->stdout);
        $version = '';
        if (preg_match('/^PHP\s+([0-9]+\.[0-9]+\.[0-9]+)/', $raw, $m)) {
            $version = $m[1];
        }
        $installed = $runtime->phpVersions();
        return ['version' => $version, 'raw' => explode("\n", $raw)[0] ?? $raw, 'installed' => $installed];
    }
}
