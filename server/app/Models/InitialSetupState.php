<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;

final class InitialSetupState extends Model
{
    public $incrementing = false;

    protected $keyType = 'int';

    /**
     * @return array<string, string>
     */
    protected function casts(): array
    {
        return [
            'completed_at' => 'datetime',
        ];
    }
}
