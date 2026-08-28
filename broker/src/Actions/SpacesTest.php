<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\SpacesClient;

final class SpacesTest
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        return SpacesClient::fromInput($input['spaces'] ?? [])->test();
    }
}
