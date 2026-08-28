<?php
declare(strict_types=1);

namespace LcmpPanel\Broker;

final class ArchiveCrypto
{
    private const MAGIC = 'LCMP1';

    public static function encrypt(string $plain, string $passphrase): string
    {
        $passphrase = Validator::password($passphrase);
        $iv = random_bytes(16);
        $key = hash('sha256', $passphrase, true);
        $cipher = openssl_encrypt($plain, 'aes-256-cbc', $key, OPENSSL_RAW_DATA, $iv);
        if ($cipher === false) {
            throw new BrokerException('Failed to encrypt archive.', 1);
        }
        return self::MAGIC . $iv . $cipher;
    }

    public static function decrypt(string $blob, string $passphrase): string
    {
        $passphrase = Validator::password($passphrase);
        if (!str_starts_with($blob, self::MAGIC) || strlen($blob) < 22) {
            throw new BrokerException('Archive is not an LCMP encrypted backup.', 2);
        }
        $iv = substr($blob, 5, 16);
        $cipher = substr($blob, 21);
        $plain = openssl_decrypt($cipher, 'aes-256-cbc', hash('sha256', $passphrase, true), OPENSSL_RAW_DATA, $iv);
        if ($plain === false) {
            throw new BrokerException('Failed to decrypt archive (wrong passphrase?).', 1);
        }
        return $plain;
    }
}
