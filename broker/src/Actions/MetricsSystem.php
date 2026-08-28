<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\ProcMetrics;
use LcmpPanel\Broker\Runtime;

final class MetricsSystem
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        return ProcMetrics::collect($runtime);
    }
}
