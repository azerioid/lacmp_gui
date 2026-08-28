<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Validator;

final class DbAdd
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $name = Validator::dbName($args[0] ?? ($input['name'] ?? ''));
        $user = Validator::userName($args[1] ?? ($input['user'] ?? $name));
        $password = Validator::password((string) ($input['password'] ?? ''));

        $existing = $runtime->dbQuery('SELECT SCHEMA_NAME FROM information_schema.SCHEMATA WHERE SCHEMA_NAME = ?', [$name]);
        if ($existing !== []) {
            throw new BrokerException('Database already exists.', 3);
        }

        $runtime->dbExec('CREATE DATABASE `' . self::ident($name) . '` CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci');
        foreach (['localhost', '127.0.0.1'] as $host) {
            $runtime->dbExec(
                'CREATE USER IF NOT EXISTS `' . self::ident($user) . '`@`' . self::ident($host) . '` IDENTIFIED BY ?',
                [$password]
            );
            $runtime->dbExec(
                'GRANT ALL PRIVILEGES ON `' . self::ident($name) . '`.* TO `' . self::ident($user) . '`@`' . self::ident($host) . '`'
            );
        }
        $runtime->dbExec('FLUSH PRIVILEGES');

        return [
            'name' => $name,
            'user' => $user,
            'hosts' => ['localhost', '127.0.0.1'],
        ];
    }

    /**
     * Identifiers are already allowlisted to [A-Za-z0-9_]{1,32}.
     * We still refuse anything that would not match, then quote with backticks.
     */
    public static function ident(string $name): string
    {
        if (!preg_match(Validator::DB_NAME_PATTERN, $name) && $name !== 'localhost' && $name !== '127.0.0.1') {
            throw new BrokerException('Unsafe SQL identifier.', 2);
        }
        return $name;
    }
}
