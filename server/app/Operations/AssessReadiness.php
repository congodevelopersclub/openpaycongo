<?php

declare(strict_types=1);

namespace App\Operations;

use Illuminate\Database\DatabaseManager;
use Throwable;

final readonly class AssessReadiness
{
    public function __construct(
        private DatabaseManager $connections,
        private MigrationReadiness $migrations,
        private ProjectionReadiness $projection,
    ) {}

    /** @return array{body: array<string, string>, status: 200|503} */
    public function assess(): array
    {
        try {
            if ($this->datastoreStatus() !== 'ok') {
                return $this->failed();
            }

            if ($this->migrations->status() !== 'current') {
                return $this->failed();
            }

            if ($this->projection->status() !== 'healthy') {
                return $this->failed();
            }

            return $this->report('ok', 'current', 'healthy', $this->migrations->revision());
        } catch (Throwable) {
            return $this->failed();
        }
    }

    /** @return 'ok'|'failed' */
    private function datastoreStatus(): string
    {
        try {
            $this->connections->connection()->getPdo();

            return 'ok';
        } catch (Throwable) {
            return 'failed';
        }
    }

    /** @return array{body: array<string, string>, status: 200|503} */
    private function failed(): array
    {
        return $this->report('failed', 'failed', 'failed', 'failed');
    }

    /** @return array{body: array<string, string>, status: 200|503} */
    private function report(string $datastore, string $migration, string $projection, string $revision): array
    {
        $ready = $datastore === 'ok' && $migration === 'current' && $projection === 'healthy';

        return [
            'body' => [
                'datastore' => $datastore,
                'migration' => $migration,
                'topology' => 'supported',
                'projection' => $projection,
                'write_admission' => $ready ? 'open' : 'closed',
                'contract_version' => 'unimplemented',
                'migration_revision' => $revision,
                'adapter' => config('database.default'),
                'implementation' => 'congo-openpay-server',
            ],
            'status' => $ready ? 200 : 503,
        ];
    }
}
