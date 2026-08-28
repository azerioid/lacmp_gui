<?php

namespace Tests\Feature;

use App\Models\User;
use App\Services\Broker\FakeBroker;
use App\Services\TotpService;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Crypt;
use Livewire\Livewire;
use Tests\TestCase;

class AuthTest extends TestCase
{
    use RefreshDatabase;

    public function test_setup_is_shown_when_no_users_exist(): void
    {
        $this->get('/login')->assertRedirect('/setup');
        $this->get('/setup')->assertOk();
    }

    public function test_login_is_a_post_mutation_via_livewire(): void
    {
        $this->get('/login')->assertRedirect('/setup');
        $this->get('/')->assertRedirect();
    }

    public function test_login_is_rate_limited(): void
    {
        $user = $this->admin();

        for ($i = 0; $i < 5; $i++) {
            Livewire::test(\App\Livewire\Auth\Login::class)
                ->set('email', $user->email)
                ->set('password', 'wrong-password-1!')
                ->call('authenticate')
                ->assertHasErrors('email');
        }

        Livewire::test(\App\Livewire\Auth\Login::class)
            ->set('email', $user->email)
            ->set('password', 'wrong-password-1!')
            ->call('authenticate')
            ->assertHasErrors('email');
    }

    public function test_two_factor_is_required_after_password(): void
    {
        $user = $this->admin();
        $this->actingAs($user);
        $this->get('/')->assertRedirect(route('two-factor.setup'));
    }

    public function test_confirmed_2fa_user_reaches_dashboard(): void
    {
        $user = $this->admin(confirmed: true);
        $this->actingAs($user);
        $this->get('/')->assertOk();
    }

    public function test_logout_is_post_only(): void
    {
        $user = $this->admin(confirmed: true);
        $this->actingAs($user);
        $this->get('/logout')->assertStatus(405);
        $this->post('/logout')->assertRedirect('/login');
    }

    public function test_security_headers_are_present(): void
    {
        $user = $this->admin(confirmed: true);
        $response = $this->actingAs($user)->get('/');
        $response->assertHeader('X-Frame-Options', 'DENY');
        $response->assertHeader('X-Content-Type-Options', 'nosniff');
        $this->assertNotEmpty($response->headers->get('Content-Security-Policy'));
    }

    public function test_guest_cannot_hit_dashboard(): void
    {
        $this->admin(confirmed: true);
        $this->get('/')->assertRedirect('/login');
    }

    private function admin(bool $confirmed = false): User
    {
        $user = User::factory()->create([
            'email' => 'admin@example.com',
            'password' => 'password',
        ]);
        if ($confirmed) {
            $totp = new TotpService();
            $secret = $totp->generateSecret();
            $user->forceFill([
                'two_factor_secret' => Crypt::encryptString($secret),
                'two_factor_confirmed_at' => now(),
            ])->save();
        }
        return $user->fresh();
    }
}
