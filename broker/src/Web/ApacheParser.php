<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Web;

final class ApacheParser
{
    /**
     * @param  list<string>  $readonlyVhosts
     * @return array<string,mixed>
     */
    public static function parseFile(string $path, string $contents, array $readonlyVhosts): array
    {
        $domain = self::match($contents, '/^\s*ServerName\s+(\S+)/m') ?? basename($path, '.conf');
        $root = self::match($contents, '/^\s*DocumentRoot\s+(\S+)/m');
        $proxy = self::match($contents, '/^\s*ProxyPass\s+\/\s+(\S+)/m');
        if (is_string($proxy)) {
            $proxy = rtrim($proxy, '/');
            $proxy = preg_replace('#^https?://#', '', $proxy) ?? $proxy;
        }
        $phpSocket = null;
        if (preg_match('/proxy:unix:([^|"]+)/', $contents, $m)) {
            $phpSocket = 'unix/' . $m[1];
        }
        $phpVersion = null;
        if ($phpSocket !== null && preg_match('/php([0-9]+\.[0-9]+)-fpm\.sock/', $phpSocket, $m)) {
            $phpVersion = $m[1];
        }

        $type = 'static';
        if ($proxy !== null && $proxy !== '') {
            $type = 'proxy';
        } elseif ($phpSocket !== null) {
            $type = 'php';
        }

        $tls = (bool) preg_match('/^\s*SSLEngine\s+on/mi', $contents);

        $basename = basename($path, '.conf');
        $readonly = $type === 'proxy';
        if (in_array($domain, $readonlyVhosts, true) || $basename === 'default' || $basename === 'lcmp-panel') {
            $readonly = true;
        }
        if (str_starts_with($domain, '127.0.0.1')) {
            $readonly = true;
        }

        return [
            'domains' => [$domain],
            'domain' => $domain,
            'root' => $root,
            'php_socket' => $phpSocket,
            'php_version' => $phpVersion,
            'type' => $type,
            'tls' => $tls,
            'reverse_proxy' => $type === 'proxy' ? $proxy : null,
            'readonly' => $readonly,
            'enabled' => true,
            'source' => $path,
        ];
    }

    private static function match(string $contents, string $pattern): ?string
    {
        if (preg_match($pattern, $contents, $m)) {
            return $m[1];
        }
        return null;
    }
}
