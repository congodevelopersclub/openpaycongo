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
            $expected = $this->expectedMigrations();

            sort($ran);

            return $expected === $ran ? 'current' : 'pending';
        } catch (Throwable) {
            return 'failed';
        }
    }

    public function revision(): string
    {
        $expected = $this->expectedMigrations();

        return $expected === [] ? 'none' : end($expected);
    }

    /** @return list<string> */
    private function expectedMigrations(): array
    {
        $expected = array_map(
            static fn (string $path): string => pathinfo($path, PATHINFO_FILENAME),
            glob(database_path('migrations/*.php')) ?: [],
        );

        sort($expected);

        return $expected;
    }
}
