<?php

declare(strict_types=1);

namespace App\DeveloperApplications;

use App\Models\DeveloperApplication;

final readonly class IssuedDeveloperApplicationCredentials
{
    public function __construct(
        public DeveloperApplication $application,
        public string $clientId,
        public string $clientSecret,
    ) {}
}
