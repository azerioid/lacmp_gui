<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\BrokerException;
use LcmpPanel\Broker\CaddyParser;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Systemd;
use LcmpPanel\Broker\Validator;

final class VhostDel
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $domain = Validator::domain($args[0] ?? ($input['domain'] ?? ''));
        $confPath = rtrim($config->caddyConfD, '/') . '/' . $domain . '.conf';

        if (!$runtime->fileExists($confPath)) {
            throw new BrokerException('Vhost config does not exist.', 3);
        }

        $contents = $runtime->readFile($confPath);
        $parsed = CaddyParser::parseFile($confPath, $contents, $config->readonlyVhosts);
        if ($parsed['readonly']) {
            throw new BrokerException('This vhost is managed externally and cannot be deleted by the panel.', 3);
        }

        $backup = $contents;
        $runtime->deleteFile($confPath);

        $validate = $runtime->exec([$config->caddyBin, 'validate', '--config', $config->caddyfile], null, 20);
        if (!$validate->ok()) {
            $runtime->writeFile($confPath, $backup, 0644);
            throw new BrokerException(
                'Caddy would fail without this vhost; the file was restored. ' . trim($validate->stderr . "\n" . $validate->stdout),
                1
            );
        }

        try {
            Systemd::control($runtime, 'reload', 'caddy');
        } catch (BrokerException $e) {
            $runtime->writeFile($confPath, $backup, 0644);
            try {
                Systemd::control($runtime, 'reload', 'caddy');
            } catch (BrokerException) {
            }
            throw new BrokerException('Caddy reload failed; the vhost file was restored. ' . $e->getMessage(), 1);
        }

        return [
            'domain' => $domain,
            'deleted' => $confPath,
            'web_root_preserved' => $parsed['root'],
        ];
    }
}
