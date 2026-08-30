<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\CaddyApply;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;

final class CaddyApplyConfig
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $mode = strtolower(trim((string) ($input['mode'] ?? $args[0] ?? 'auto')));
        $ports = $input['expect_ports'] ?? [];
        if (!is_array($ports)) {
            throw new BrokerException('expect_ports must be an array of integers.', 2);
        }
        $expect = [];
        foreach ($ports as $p) {
            $expect[] = (int) $p;
        }

        return CaddyApply::run($runtime, $config, $mode, $expect);
    }
}
