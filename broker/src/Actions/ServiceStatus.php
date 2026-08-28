<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Systemd;
use LcmpPanel\Broker\Validator;

final class ServiceStatus
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $unit = Validator::service($args[0] ?? '', $config->controllableServiceList($runtime));
        return [
            'parsed' => Systemd::show($runtime, $unit),
            'raw' => Systemd::statusRaw($runtime, $unit),
            'journal' => Systemd::journal($runtime, $unit),
        ];
    }
}
