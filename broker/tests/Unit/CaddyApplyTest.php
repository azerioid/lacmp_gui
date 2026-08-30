<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Tests;

use LcmpPanel\Broker\CaddyApply;
use LcmpPanel\Broker\Config;
use LcmpPanel\Broker\FakeRuntime;
use LcmpPanel\Broker\Kernel;
use PHPUnit\Framework\TestCase;

final class CaddyApplyTest extends TestCase
{
    public function test_client_address_never_uses_localhost(): void
    {
        $this->assertSame('127.0.0.1:2019', CaddyApply::clientAddress('localhost:2019'));
        $this->assertSame('127.0.0.1:2019', CaddyApply::clientAddress('default'));
        $this->assertSame('127.0.0.1:2019', CaddyApply::clientAddress('off'));
        $this->assertSame('127.0.0.1:2019', CaddyApply::clientAddress('http://localhost:2019'));
        $this->assertSame('unix//run/caddy-admin.sock', CaddyApply::clientAddress('unix//run/caddy-admin.sock'));
    }

    public function test_apply_uses_explicit_ipv4_api_without_restart(): void
    {
        $rt = new FakeRuntime();
        $rt->files['/etc/caddy/Caddyfile'] = "{\n    admin 127.0.0.1:2019\n}\nimport /etc/caddy/conf.d/*.conf\n";
        $rt->script(['/usr/bin/caddy', 'validate', '--config', '/etc/caddy/Caddyfile'], 0, 'Valid configuration');
        $rt->script(['/usr/bin/caddy', 'reload', '--config', '/etc/caddy/Caddyfile', '--address', '127.0.0.1:2019', '--force'], 0);
        $rt->script(['/usr/bin/systemctl', 'restart', 'caddy'], 1, '', 'restart must not run');

        $kernel = new Kernel(new Config(), $rt);
        ob_start();
        $code = $kernel->run(['broker', 'caddy.apply'], ['mode' => 'auto', 'expect_ports' => []]);
        $out = ob_get_clean();

        $this->assertSame(0, $code);
        $decoded = json_decode($out, true);
        $this->assertTrue($decoded['ok']);
        $this->assertSame('api', $decoded['data']['path']);
        $this->assertSame('127.0.0.1:2019', $decoded['data']['address']);
        $this->assertFalse($decoded['data']['admin_enabled']);
        $restarts = array_filter($rt->execLog, fn ($e) => ($e['command'][1] ?? '') === 'restart');
        $this->assertSame([], $restarts);
    }

    public function test_port_health_failure_is_specific(): void
    {
        $rt = new FakeRuntime();
        $rt->files['/etc/caddy/Caddyfile'] = "{\n    admin 127.0.0.1:2019\n}\n";
        $rt->script(['/usr/bin/caddy', 'validate', '--config', '/etc/caddy/Caddyfile'], 0, 'Valid configuration');
        $rt->script(['/usr/bin/ss', '-tln'], 0, 'LISTEN 0 4096 127.0.0.1:80\n');

        $kernel = new Kernel(new Config(), $rt);
        ob_start();
        $code = $kernel->run(['broker', 'caddy.apply'], ['mode' => 'auto', 'expect_ports' => [6969]]);
        $out = ob_get_clean();

        $this->assertNotSame(0, $code);
        $this->assertStringContainsString('nothing is listening on port 6969', $out);
    }
}
