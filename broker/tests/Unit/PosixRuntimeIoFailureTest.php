<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Tests;

use LcmpPanel\Broker\PosixRuntime;
use PHPUnit\Framework\TestCase;

final class PosixRuntimeIoFailureTest extends TestCase
{
    public function test_erofs_message_points_at_fpm_sandbox(): void
    {
        $msg = PosixRuntime::describeIoFailure('write', '/etc/caddy/conf.d/abc.com.conf.lcmp-tmp', [
            'message' => 'file_put_contents(/etc/caddy/conf.d/abc.com.conf.lcmp-tmp): Failed to open stream: Read-only file system',
        ]);
        $this->assertStringContainsString('read-only for the broker context', $msg);
        $this->assertStringContainsString('ProtectSystem', $msg);
        $this->assertStringContainsString('ReadWritePaths', $msg);
    }

    public function test_open_basedir_stays_specific(): void
    {
        $msg = PosixRuntime::describeIoFailure('write', '/etc/caddy/conf.d/x.conf', [
            'message' => 'file_put_contents(): open_basedir restriction in effect',
        ]);
        $this->assertStringContainsString('open_basedir', $msg);
    }
}
