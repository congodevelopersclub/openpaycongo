<?php

declare(strict_types=1);

namespace App\Support;

use JsonException;
use RuntimeException;

final class CanonicalAnalyticsFixture
{
    /** @return array<string, mixed> */
    public function response(): array
    {
        $encoded = file_get_contents(base_path('../docs/sales-analytics-response.valid.json'));

        if ($encoded === false) {
            throw new RuntimeException('Canonical analytics fixture is unavailable.');
        }

        try {
            /** @var array<string, mixed> $fixture */
            $fixture = json_decode($encoded, true, flags: JSON_THROW_ON_ERROR);
        } catch (JsonException $exception) {
            throw new RuntimeException('Canonical analytics fixture is invalid.', previous: $exception);
        }

        return $fixture;
    }
}
