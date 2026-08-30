<?php
declare(strict_types=1);

namespace LcmpPanel\Broker;

use PDO;
use PDOException;

/**
 * Production runtime: real filesystem, proc_open argv (no shell), PDO MariaDB.
 */
final class PosixRuntime implements Runtime
{
    private ?PDO $pdo = null;

    public function __construct(
        private readonly ?string $mysqlSocket = null,
        private readonly ?string $mysqlUser = null,
        private readonly ?string $mysqlPassword = null,
    ) {
    }

    public function withDatabase(string $socket, string $user, string $password): self
    {
        return new self($socket, $user, $password);
    }

    public function exec(array $command, ?string $stdin = null, int $timeoutSeconds = 30): ExecResult
    {
        if ($command === []) {
            throw new BrokerException('Refusing to execute an empty command.', 1);
        }
        foreach ($command as $part) {
            if (!is_string($part)) {
                throw new BrokerException('Command argv must be strings.', 1);
            }
        }

        $descriptors = [
            0 => ['pipe', 'r'],
            1 => ['pipe', 'w'],
            2 => ['pipe', 'w'],
        ];

        $proc = @proc_open($command, $descriptors, $pipes, null, null, [
            'bypass_shell' => true,
        ]);
        if (!is_resource($proc)) {
            throw new BrokerException('Failed to spawn process.', 1);
        }

        if ($stdin !== null) {
            fwrite($pipes[0], $stdin);
        }
        fclose($pipes[0]);

        stream_set_blocking($pipes[1], false);
        stream_set_blocking($pipes[2], false);

        $stdout = '';
        $stderr = '';
        $deadline = microtime(true) + $timeoutSeconds;

        do {
            $status = proc_get_status($proc);
            $stdout .= (string) stream_get_contents($pipes[1]);
            $stderr .= (string) stream_get_contents($pipes[2]);
            if (!$status['running']) {
                break;
            }
            if (microtime(true) > $deadline) {
                proc_terminate($proc, 9);
                fclose($pipes[1]);
                fclose($pipes[2]);
                proc_close($proc);
                throw new BrokerException('Process timed out.', 1);
            }
            usleep(20000);
        } while (true);

        $stdout .= (string) stream_get_contents($pipes[1]);
        $stderr .= (string) stream_get_contents($pipes[2]);
        fclose($pipes[1]);
        fclose($pipes[2]);
        $exit = proc_close($proc);

        return new ExecResult($command, (int) ($status['exitcode'] ?? $exit), $stdout, $stderr);
    }

    public function readFile(string $path): string
    {
        $data = @file_get_contents($path);
        if ($data === false) {
            throw new BrokerException("Unable to read {$path}.", 1);
        }
        return $data;
    }

    public function writeFile(string $path, string $contents, int $mode = 0644): void
    {
        $dir = dirname($path);
        if (!is_dir($dir)) {
            throw new BrokerException("Directory does not exist: {$dir}", 1);
        }
        if (@file_put_contents($path, $contents, LOCK_EX) === false) {
            throw new BrokerException('Could not save the vhost configuration through the broker.', 1);
        }
        @chmod($path, $mode);
    }

    public function rename(string $from, string $to): void
    {
        if (!@rename($from, $to)) {
            @unlink($from);
            throw new BrokerException('Could not install the vhost configuration through the broker.', 1);
        }
    }

    public function deleteFile(string $path): void
    {
        if (is_file($path) && !@unlink($path)) {
            throw new BrokerException("Unable to delete {$path}.", 1);
        }
    }

    public function fileExists(string $path): bool
    {
        return file_exists($path);
    }

    public function isDir(string $path): bool
    {
        return is_dir($path);
    }

    public function mkdir(string $path, int $mode = 0755): void
    {
        if (is_dir($path)) {
            return;
        }
        if (!@mkdir($path, $mode, true) && !is_dir($path)) {
            throw new BrokerException("Unable to create directory {$path}.", 1);
        }
    }

    public function listDir(string $path): array
    {
        if (!is_dir($path)) {
            return [];
        }
        $entries = scandir($path);
        if ($entries === false) {
            return [];
        }
        return array_values(array_filter($entries, static fn ($e) => $e !== '.' && $e !== '..'));
    }

    public function glob(string $pattern): array
    {
        $matches = glob($pattern) ?: [];
        sort($matches);
        return $matches;
    }

    public function chmod(string $path, int $mode): void
    {
        @chmod($path, $mode);
    }

    public function chown(string $path, string $user, string $group): void
    {
        @chown($path, $user);
        @chgrp($path, $group);
    }

    public function resolveUnderBase(string $path, string $base): ?string
    {
        $baseReal = realpath($base) ?: $base;
        $baseReal = rtrim($baseReal, '/');

        if (file_exists($path)) {
            $real = realpath($path);
            if ($real === false) {
                return null;
            }
            if ($real === $baseReal || str_starts_with($real, $baseReal . '/')) {
                return $real;
            }
            return null;
        }

        $current = $path;
        while ($current !== '/' && $current !== '' && !file_exists($current)) {
            $current = dirname($current);
        }
        $parentReal = realpath($current);
        if ($parentReal === false) {
            return null;
        }
        if ($parentReal !== $baseReal && !str_starts_with($parentReal, $baseReal . '/')) {
            return null;
        }

        $suffix = substr($path, strlen($current));
        return rtrim($parentReal, '/') . $suffix;
    }

    public function getuid(): int
    {
        return function_exists('posix_geteuid') ? posix_geteuid() : (int) getmyuid();
    }

    public function now(): string
    {
        return gmdate('c');
    }

    public function phpVersions(): array
    {
        $versions = [];
        if (is_dir('/etc/php')) {
            foreach (scandir('/etc/php') ?: [] as $entry) {
                if (preg_match('/^[0-9]+\.[0-9]+$/', $entry) && is_dir('/etc/php/' . $entry)) {
                    $versions[] = $entry;
                }
            }
        }
        sort($versions, SORT_NATURAL);
        return $versions;
    }

    public function dbQuery(string $sql, array $params = []): array
    {
        $stmt = $this->pdo()->prepare($sql);
        $stmt->execute($params);
        return $stmt->fetchAll(PDO::FETCH_ASSOC) ?: [];
    }

    public function dbExec(string $sql, array $params = []): int
    {
        $stmt = $this->pdo()->prepare($sql);
        $stmt->execute($params);
        return $stmt->rowCount();
    }

    private function pdo(): PDO
    {
        if ($this->pdo instanceof PDO) {
            return $this->pdo;
        }
        if ($this->mysqlSocket === null || $this->mysqlUser === null || $this->mysqlPassword === null) {
            throw new BrokerException('MariaDB credentials are not configured on the broker.', 1);
        }
        try {
            $dsn = 'mysql:unix_socket=' . $this->mysqlSocket . ';charset=utf8mb4';
            $this->pdo = new PDO($dsn, $this->mysqlUser, $this->mysqlPassword, [
                PDO::ATTR_ERRMODE => PDO::ERRMODE_EXCEPTION,
                PDO::ATTR_EMULATE_PREPARES => false,
            ]);
        } catch (PDOException $e) {
            throw new BrokerException('MariaDB connection failed.', 1);
        }
        return $this->pdo;
    }
}
