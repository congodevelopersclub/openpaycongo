<?php

namespace App\Setup;

use App\Models\SecurityAudit;
use App\Models\User;

final class RecordSecurityAudit
{
    public function record(User $user, string $action): void
    {
        SecurityAudit::query()->create([
            'user_id' => $user->getKey(),
            'action' => $action,
        ]);
    }
}
