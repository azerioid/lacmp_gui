<div>
    <h2 class="mb-1 text-base font-medium text-zinc-100">Two-factor is required</h2>
    <p class="mb-4 text-sm text-zinc-500">This panel can restart services and drop databases. TOTP is not optional.</p>
    <div class="mb-4 flex justify-center rounded-md bg-white p-3">{!! $qr !!}</div>
    <p class="mb-4 break-all text-center font-mono text-xs text-zinc-400">{{ $secret }}</p>
    <form wire:submit="confirm" class="space-y-4">
        <input type="text" inputmode="numeric" wire:model="code" maxlength="6" class="field text-center tracking-[0.4em]" placeholder="000000">
        @error('code') <p class="text-sm text-bad">{{ $message }}</p> @enderror
        <button type="submit" class="btn-primary w-full">Enable 2FA</button>
    </form>
</div>
