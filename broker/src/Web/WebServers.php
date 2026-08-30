<?php
declare(strict_types=1);

namespace LcmpPanel\Broker\Web;

use LcmpPanel\Broker\Config;

final class WebServers
{
    public static function for(Config $config): WebServerDriver
    {
        return $config->stack === 'lamp' ? new ApacheDriver($config) : new CaddyDriver();
    }
}
