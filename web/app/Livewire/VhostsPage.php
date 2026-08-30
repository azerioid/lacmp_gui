<?php

namespace App\Livewire;

use App\Services\Broker\BrokerCallException;
use App\Services\Broker\BrokerClient;
use LcmpPanel\Broker\Validator;
use Livewire\Attributes\Layout;
use Livewire\Attributes\Title;
use Livewire\Component;

#[Layout('layouts.app')]
#[Title('Virtual hosts · LCMP Panel')]
class VhostsPage extends Component
{
    public array $vhosts = [];
    public array $phpVersions = [];
    public string $domain = '';
    public string $root = '';
    public string $type = 'php';
    public string $php_version = '';
    public string $upstream = '127.0.0.1:9000';
    public ?string $error = null;
    public ?string $flash = null;
    public ?string $confirmDelete = null;
    public bool $showForm = false;

    public function mount(BrokerClient $broker): void
    {
        $this->reload($broker);
    }

    public function updatedDomain(): void
    {
        if ($this->root === '' && $this->domain !== '') {
            try {
                $d = Validator::domain($this->domain);
                $this->root = rtrim((string) config('lcmp.www_root'), '/') . '/' . $d;
            } catch (\Throwable) {
            }
        }
    }

    public function create(BrokerClient $broker): void
    {
        $this->error = null;
        try {
            $domain = Validator::domain($this->domain);
            $root = Validator::webRoot($this->root, (string) config('lcmp.www_root'), new \LcmpPanel\Broker\FakeRuntime());
            $type = Validator::vhostType($this->type);
            $args = [$domain, $root, $type];
            if ($type === 'php') {
                $args[] = Validator::phpVersion($this->php_version, $this->phpVersions);
            } elseif ($type === 'proxy') {
                $args[] = Validator::localUpstream($this->upstream);
            }
            $res = $broker->call('vhost.add', $args);
            if (! $res->ok) {
                $this->error = $res->error;
                return;
            }
            $this->flash = "Created {$domain}. Caddy was validated and reloaded.";
            $this->reset('domain', 'root', 'type', 'upstream', 'showForm');
            $this->reload($broker);
        } catch (\Throwable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function delete(BrokerClient $broker, string $domain): void
    {
        $res = $broker->call('vhost.del', [Validator::domain($domain)]);
        if (! $res->ok) {
            $this->error = $res->error;
        } else {
            $this->flash = "Deleted {$domain}. Website files were left in place.";
        }
        $this->confirmDelete = null;
        $this->reload($broker);
    }

    private function reload(BrokerClient $broker): void
    {
        try {
            $this->vhosts = $broker->call('vhost.list')->dataOrFail()['vhosts'] ?? [];
            $php = $broker->call('php.versions')->dataOrFail()['versions'] ?? [];
            $this->phpVersions = array_column($php, 'version');
            if ($this->php_version === '' && $this->phpVersions !== []) {
                $this->php_version = $this->phpVersions[array_key_last($this->phpVersions)];
            }
        } catch (BrokerCallException $e) {
            $this->error = $e->getMessage();
        }
    }

    public function render()
    {
        return view('livewire.vhosts')->layoutData([
            'heading' => 'Virtual hosts',
            'sub' => 'Reverse-proxy and protected vhosts are read-only',
        ]);
    }
}
