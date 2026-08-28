<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\CaddyParser;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;

final class VhostList
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $files = $runtime->glob(rtrim($config->caddyConfD, '/') . '/*.conf');
        $sites = [];
        foreach ($files as $file) {
            try {
                $contents = $runtime->readFile($file);
            } catch (\Throwable) {
                continue;
            }
            $sites[] = CaddyParser::parseFile($file, $contents, $config->readonlyVhosts);
        }
        usort($sites, static fn ($a, $b) => strcmp($a['domain'], $b['domain']));
        return ['vhosts' => $sites];
    }
}
