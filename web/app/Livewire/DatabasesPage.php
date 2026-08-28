<?php

namespace App\Livewire;

use App\Services\Broker\BrokerCallException;
use App\Services\Broker\BrokerClient;
use App\Support\Format;
use LcmpPanel\Broker\Validator;
use Livewire\Attributes\Layout;
use Livewire\Attributes\Title;
use Livewire\Component;

#[Layout('layouts.app')]
#[Title('Databases · LCMP Panel')]
class DatabasesPage extends Component
{
    public array $databases = [];
    public string $name = '';
    public string $user = '';
    public ?string $revealedPassword = null;
    public ?string $error = null;
    public ?string $flash = null;
    public ?string $confirmDelete = null;
    public string $confirmTyped = '';
    public ?string $resetUser = null;
    public ?string $resetPassword = null;
    public bool $showForm = false;

    public function mount(BrokerClient $broker): void
    {
        $this->reload($broker);
    }

    public function generate(): void
    {
        $this->revealedPassword = Format::password();
    }

    public function create(BrokerClient $broker): void
    {
        $this->error = null;
        try {
            $name = Validator::dbName($this->name);
            $user = Validator::userName($this->user !== '' ? $this->user : $this->name);
            if ($this->revealedPassword === null) {
                $this->revealedPassword = Format::password();
            }
            Validator::password($this->revealedPassword);
            $res = $broker->call('db.add', [$name, $user], ['password' => $this->revealedPassword]);
            if (! $res->ok) {
                $this->error = $res->error;
                return;
            }
            $this->flash = "Created database {$name}. Copy the password now — it will not be shown again.";
            $this->reset('name', 'user', 'showForm');
            $this->reload($broker);
        } catch (\Throwable $e) {
            $this->error = $e->getMessage();
        }
    }

    public function delete(BrokerClient $broker): void
    {
        if ($this->confirmDelete === null || $this->confirmTyped !== $this->confirmDelete) {
            $this->error = 'Type the database name to confirm deletion.';
            return;
        }
        $res = $broker->call('db.del', [Validator::dbName($this->confirmDelete)]);
        $this->error = $res->ok ? null : $res->error;
        $this->flash = $res->ok ? 'Database dropped.' : null;
        $this->confirmDelete = null;
        $this->confirmTyped = '';
        $this->reload($broker);
    }

    public function startReset(string $user): void
    {
        $this->resetUser = $user;
        $this->resetPassword = Format::password();
    }

    public function confirmReset(BrokerClient $broker): void
    {
        if ($this->resetUser === null || $this->resetPassword === null) {
            return;
        }
        $res = $broker->call('db.resetpw', [Validator::userName($this->resetUser)], ['password' => $this->resetPassword]);
        $this->error = $res->ok ? null : $res->error;
        $this->flash = $res->ok ? 'Password reset. Copy it now.' : null;
        $this->revealedPassword = $res->ok ? $this->resetPassword : $this->revealedPassword;
        $this->resetUser = null;
        $this->resetPassword = null;
        $this->reload($broker);
    }

    private function reload(BrokerClient $broker): void
    {
        try {
            $this->databases = $broker->call('db.list')->dataOrFail()['databases'] ?? [];
        } catch (BrokerCallException $e) {
            $this->error = $e->getMessage();
        }
    }

    public function render()
    {
        return view('livewire.databases', [
            'format' => Format::class,
        ])->layoutData([
            'heading' => 'Databases',
            'sub' => 'MariaDB · passwords are one-time reveal',
        ]);
    }
}
