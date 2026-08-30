<?php

declare(strict_types=1);

namespace App\Operations;

interface ProjectionReadiness
{
    /** @return 'healthy'|'failed' */
    public function status(): string;
}
