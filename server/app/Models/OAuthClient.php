<?php

namespace App\Models;

use Laravel\Passport\Client;

final class OAuthClient extends Client
{
    protected function casts(): array
    {
        return [
            ...parent::casts(),
            'last_used_at' => 'datetime',
        ];
    }
}
