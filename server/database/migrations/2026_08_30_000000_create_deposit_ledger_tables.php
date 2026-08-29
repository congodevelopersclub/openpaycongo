<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    private const DEPOSIT_KIND_LENGTH = 32;

    public function up(): void
    {
        Schema::create('customers', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id');
            $table->char('private_lookup_digest', 64);
            $table->timestamps();
            $table->unique(['organization_id', 'private_lookup_digest']);
        });

        Schema::create('source_installations', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id');
            $table->char('installation_digest', 64);
            $table->timestamps();
            $table->unique(['organization_id', 'installation_digest']);
        });

        Schema::create('deposits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id');
            $table->foreignUuid('customer_id')->constrained();
            $table->foreignUuid('source_installation_id')->constrained();
            $table->foreignUuid('reverses_deposit_id')->nullable()->unique()->constrained('deposits');
            $table->string('kind', self::DEPOSIT_KIND_LENGTH);
            $table->unsignedBigInteger('amount_minor');
            $table->char('currency', 3);
            $table->text('provider_reference')->nullable();
            $table->char('provider_reference_digest', 64)->nullable();
            $table->dateTime('provider_occurred_at')->nullable();
            $table->timestampTz('received_at');
            $table->text('sender_identifier')->nullable();
            $table->text('receiver_identifier')->nullable();
            $table->char('idempotency_digest', 64);
            $table->timestamps();
            $table->unique(['organization_id', 'provider_reference_digest']);
            $table->unique(['organization_id', 'idempotency_digest']);
        });

        Schema::create('ledger_entries', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('deposit_id')->constrained();
            $table->uuid('organization_id');
            $table->string('account', 64);
            $table->unsignedBigInteger('debit_minor')->default(0);
            $table->unsignedBigInteger('credit_minor')->default(0);
            $table->char('currency', 3);
            $table->timestampTz('recorded_at');
            $table->timestamps();
            $table->index(['organization_id', 'account', 'currency']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('ledger_entries');
        Schema::dropIfExists('deposits');
        Schema::dropIfExists('source_installations');
        Schema::dropIfExists('customers');
    }
};
