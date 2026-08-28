<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Validator;

final class DbResetpw
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $user = Validator::userName($args[0] ?? ($input['user'] ?? ''));
        $password = Validator::password((string) ($input['password'] ?? ''));

        foreach (['localhost', '127.0.0.1'] as $host) {
            $runtime->dbExec(
                'ALTER USER `' . DbAdd::ident($user) . '`@`' . DbAdd::ident($host) . '` IDENTIFIED BY ?',
                [$password]
            );
        }
        $runtime->dbExec('FLUSH PRIVILEGES');

        return ['user' => $user, 'reset' => true];
    }
}
