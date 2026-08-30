<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Web\WebServers;

final class VhostList
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        return ['vhosts' => WebServers::for($config)->listVhosts($runtime, $config)];
    }
}
