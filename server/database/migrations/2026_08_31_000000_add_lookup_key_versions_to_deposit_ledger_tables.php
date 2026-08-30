<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

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
            $table->unique(['organization_id', 'private_lookup_id']);
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->uuid('installation_lookup_id')->nullable();
            $table->string('installation_key_version', 64)->nullable();
            $table->unique(['organization_id', 'installation_lookup_id']);
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->uuid('provider_reference_lookup_id')->nullable();
            $table->string('provider_reference_key_version', 64)->nullable();
            $table->string('idempotency_key_version', 64)->nullable();
            $table->unique(['organization_id', 'provider_reference_lookup_id']);
        });
    }

    public function down(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropUnique(['organization_id', 'provider_reference_lookup_id']);
            $table->dropColumn(['provider_reference_lookup_id', 'provider_reference_key_version', 'idempotency_key_version']);
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropUnique(['organization_id', 'installation_lookup_id']);
            $table->dropColumn(['installation_lookup_id', 'installation_key_version']);
        });

        Schema::table('customers', function (Blueprint $table): void {
            $table->dropUnique(['organization_id', 'private_lookup_id']);
            $table->dropColumn(['private_lookup_id', 'private_lookup_key_version']);
        });

        Schema::dropIfExists('private_lookup_aliases');
    }
};
