<?php
declare(strict_types=1);

namespace LcmpPanel\Broker;

final class BrokerException extends \RuntimeException
{
    public function __construct(
        string $message,
        public readonly int $errorCode = 1,
    ) {
        parent::__construct($message, $errorCode);
    }
}
