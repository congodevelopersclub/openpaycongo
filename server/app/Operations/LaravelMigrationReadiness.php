<?php

declare(strict_types=1);

namespace App\Operations;

use Illuminate\Database\Migrations\Migrator;
use Throwable;

final readonly class LaravelMigrationReadiness implements MigrationReadiness
{
    public function __construct(private Migrator $migrator) {}

    public function status(): string
    {
        try {
            if (! $this->migrator->repositoryExists()) {
                return 'pending';
            }

            $ran = $this->migrator->getRepository()->getRan();
            $expected = array_map(
                static fn (string $path): string => pathinfo($path, PATHINFO_FILENAME),
                glob(database_path('migrations/*.php')) ?: [],
            );

            return array_diff($expected, $ran) === [] ? 'current' : 'pending';
        } catch (Throwable) {
            return 'failed';
        }
    }

    public function revision(): string
    {
        $ran = $this->migrator->getRepository()->getRan();

        return $ran === [] ? 'none' : end($ran);
    }
}
