<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('customers', function (Blueprint $table): void {
            $table->string('private_lookup_key_version', 64)->nullable();
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->string('installation_key_version', 64)->nullable();
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->string('provider_reference_key_version', 64)->nullable();
            $table->string('idempotency_key_version', 64)->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropColumn(['provider_reference_key_version', 'idempotency_key_version']);
        });

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropColumn('installation_key_version');
        });

        Schema::table('customers', function (Blueprint $table): void {
            $table->dropColumn('private_lookup_key_version');
        });
    }
};
