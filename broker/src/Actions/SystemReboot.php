<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Validator;

final class SystemReboot
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        Validator::typedConfirm((string) ($input['confirm'] ?? ''), 'REBOOT');
        $runtime->exec(['/usr/sbin/reboot'], null, 5);
        return ['accepted' => true];
    }
}
