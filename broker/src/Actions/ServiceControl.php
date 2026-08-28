<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Systemd;
use LcmpPanel\Broker\Validator;

final class ServiceControl
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $verb = match ($action) {
            'service.start' => 'start',
            'service.stop' => 'stop',
            'service.restart' => 'restart',
            default => throw new BrokerException('Unknown service action.', 2),
        };
        $unit = Validator::service($args[0] ?? '', $config->controllableServiceList($runtime));
        return Systemd::control($runtime, $verb, $unit);
    }
}
