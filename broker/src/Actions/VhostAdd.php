<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Validator;
use LcmpPanel\Broker\Web\WebServers;

final class VhostAdd
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $domain = Validator::domain($args[0] ?? ($input['domain'] ?? ''));
        $root = Validator::webRoot((string) ($args[1] ?? ($input['root'] ?? '')), $config->wwwRoot, $runtime);
        $type = Validator::vhostType((string) ($args[2] ?? ($input['type'] ?? 'php')));

        $phpVersion = null;
        $upstream = null;
        if ($type === 'php') {
            $phpVersion = Validator::phpVersion((string) ($args[3] ?? ($input['php_version'] ?? '')), $runtime->phpVersions());
        }
        if ($type === 'proxy') {
            $upstream = Validator::localUpstream((string) ($args[3] ?? ($input['upstream'] ?? '')));
        }

        $blocked = array_map('strtolower', $config->readonlyVhosts);
        if (in_array($domain, $blocked, true) || $domain === 'default' || $domain === 'lcmp-panel') {
            throw new BrokerException("{$domain} is managed externally and can't be edited.", 3);
        }

        return WebServers::for($config)->addVhost($runtime, $config, [
            'domain' => $domain,
            'root' => $root,
            'type' => $type,
            'php_version' => $phpVersion,
            'upstream' => $upstream,
        ]);
    }
}
