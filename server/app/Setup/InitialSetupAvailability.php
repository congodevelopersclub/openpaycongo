<?php

namespace App\Setup;

use App\Models\InitialSetupState;

final readonly class InitialSetupAvailability
{
    public function isAvailable(): bool
    {
        return InitialSetupState::query()
            ->whereKey(1)
            ->whereNull('completed_at')
            ->exists();
    }
}
