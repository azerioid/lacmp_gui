<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Tests;

use LcmpPanel\Broker\Web\ApacheParser;
use PHPUnit\Framework\TestCase;

final class ApacheParserTest extends TestCase
{
    public function test_parses_php_vhost(): void
    {
        $contents = <<<'APACHE'
<VirtualHost *:80>
    ServerName shop.example.com
    DocumentRoot /data/www/shop.example.com
    <FilesMatch \.php$>
        SetHandler "proxy:unix:/run/php/php8.4-fpm.sock|fcgi://localhost"
    </FilesMatch>
</VirtualHost>
APACHE;
        $parsed = ApacheParser::parseFile('/etc/apache2/sites-available/shop.example.com.conf', $contents, []);
        $this->assertSame('shop.example.com', $parsed['domain']);
        $this->assertSame('php', $parsed['type']);
        $this->assertSame('8.4', $parsed['php_version']);
        $this->assertFalse($parsed['readonly']);
    }

    public function test_marks_proxy_readonly(): void
    {
        $contents = <<<'APACHE'
<VirtualHost *:80>
    ServerName app.example
    ProxyPass / http://127.0.0.1:9001/
    ProxyPassReverse / http://127.0.0.1:9001/
</VirtualHost>
APACHE;
        $parsed = ApacheParser::parseFile('/etc/apache2/sites-available/app.example.conf', $contents, []);
        $this->assertSame('proxy', $parsed['type']);
        $this->assertTrue($parsed['readonly']);
        $this->assertSame('127.0.0.1:9001', $parsed['reverse_proxy']);
    }
}
