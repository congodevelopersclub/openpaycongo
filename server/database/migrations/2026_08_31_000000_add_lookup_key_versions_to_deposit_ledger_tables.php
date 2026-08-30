<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('private_lookup_aliases', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id');
            $table->string('purpose', 64);
            $table->char('digest', 64);
            $table->uuid('lookup_id');
            $table->dateTime('created_at')->nullable();
            $table->unique(['organization_id', 'purpose', 'digest']);
            $table->index(['organization_id', 'purpose', 'lookup_id']);
        });

        Schema::table('customers', function (Blueprint $table): void {
            $table->uuid('private_lookup_id')->nullable();
            $table->string('private_lookup_key_version', 64)->nullable();
            $table->unique(['organization_id', 'private_lookup_id'], 'customers_org_lookup_unique');
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->uuid('installation_lookup_id')->nullable();
            $table->string('installation_key_version', 64)->nullable();
            $table->unique(['organization_id', 'installation_lookup_id'], 'installations_org_lookup_unique');
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->uuid('provider_reference_lookup_id')->nullable();
            $table->string('provider_reference_key_version', 64)->nullable();
            $table->string('idempotency_key_version', 64)->nullable();
            $table->unique(['organization_id', 'provider_reference_lookup_id'], 'deposits_org_provider_lookup_unique');
        });

        $this->backfillAliases('customers', 'private_lookup_digest', 'private_lookup_id', 'customer_lookup');
        $this->backfillAliases('source_installations', 'installation_digest', 'installation_lookup_id', 'installation_lookup');
        $this->backfillAliases('deposits', 'provider_reference_digest', 'provider_reference_lookup_id', 'provider_reference');
    }

    public function down(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropUnique('deposits_org_provider_lookup_unique');
            $table->dropColumn(['provider_reference_lookup_id', 'provider_reference_key_version', 'idempotency_key_version']);
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropUnique('installations_org_lookup_unique');
            $table->dropColumn(['installation_lookup_id', 'installation_key_version']);
        });

        Schema::table('customers', function (Blueprint $table): void {
            $table->dropUnique('customers_org_lookup_unique');
            $table->dropColumn(['private_lookup_id', 'private_lookup_key_version']);
        });

        Schema::dropIfExists('private_lookup_aliases');
    }

    private function backfillAliases(string $table, string $digestColumn, string $lookupIdColumn, string $purpose): void
    {
        foreach (DB::table($table)->whereNotNull($digestColumn)->whereNull($lookupIdColumn)->orderBy('id')->cursor() as $row) {
            $lookupId = (string) Str::uuid();
            DB::table('private_lookup_aliases')->insert([
                'id' => (string) Str::uuid(), 'organization_id' => $row->organization_id, 'purpose' => $purpose,
                'digest' => $row->{$digestColumn}, 'lookup_id' => $lookupId, 'created_at' => now(),
            ]);
            DB::table($table)->where('id', $row->id)->update([$lookupIdColumn => $lookupId]);
        }
    }
};
