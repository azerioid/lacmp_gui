<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Actions;

use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\ProcMetrics;
use LcmpPanel\Broker\Runtime;
use LcmpPanel\Broker\Systemd;

final class StatusAll
{
    public function handle(string $action, array $args, array $input, Runtime $runtime, Config $config): array
    {
        $controlled = [];
        foreach ($config->controllableServiceList($runtime) as $unit) {
            $info = Systemd::show($runtime, $unit) + ['controllable' => true];
            if (($info['active_state'] ?? '') === 'failed') {
                $info['journal'] = Systemd::journal($runtime, $unit, 40);
            }
            $controlled[] = $info;
        }

        $observed = [];
        foreach ($config->observedServices as $unit) {
            $info = Systemd::show($runtime, $unit);
            $info['controllable'] = false;
            $observed[] = $info;
        }

        $observed[] = self::probePort($runtime, 'roadrunner', '127.0.0.1', 8000, 'projob.az RoadRunner');
        $observed[] = self::probePort($runtime, 'roadrunner-rpc', '127.0.0.1', 6001, 'projob.az RoadRunner RPC');
        $observed[] = self::probePort($runtime, 'pong', '0.0.0.0', 8080, 'Node.js pong');

        return [
            'controlled' => $controlled,
            'observed' => $observed,
            'warnings' => self::warnings($runtime, $config),
        ];
    }

    private static function probePort(Runtime $runtime, string $id, string $bindHint, int $port, string $label): array
    {
        $listening = false;
        foreach (['/proc/net/tcp', '/proc/net/tcp6'] as $path) {
            if (!$runtime->fileExists($path)) {
                continue;
            }
            $hexPort = strtoupper(str_pad(dechex($port), 4, '0', STR_PAD_LEFT));
            foreach (explode("\n", $runtime->readFile($path)) as $line) {
                if (preg_match('/:[0-9A-F]*' . $hexPort . '\s+\S+\s+0A/i', $line)) {
                    $listening = true;
                    break 2;
                }
            }
        }
        return [
            'unit' => $id,
            'id' => $id,
            'description' => $label,
            'active_state' => $listening ? 'active' : 'inactive',
            'sub_state' => $listening ? 'running' : 'dead',
            'running' => $listening,
            'controllable' => false,
            'bind_hint' => $bindHint . ':' . $port,
        ];
    }

    private static function warnings(Runtime $runtime, Config $config): array
    {
        $warnings = [];
        if (ProcMetrics::mariadbBindFromProcNet($runtime)) {
            $warnings[] = [
                'id' => 'mariadb_public_bind',
                'severity' => 'high',
                'title' => 'MariaDB is listening on 0.0.0.0:3306',
                'body' => 'The database port is reachable on all interfaces. Bind it to 127.0.0.1 unless a remote app genuinely needs network access. The panel will not change this automatically.',
            ];
        }
        return $warnings;
    }
}
