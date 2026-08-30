<?php

declare(strict_types=1);

namespace App\Operations;

interface MigrationReadiness
{
    /** @return 'current'|'pending'|'failed' */
    public function status(): string;

    public function revision(): string;
}
