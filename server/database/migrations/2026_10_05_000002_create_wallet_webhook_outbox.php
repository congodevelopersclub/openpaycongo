<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('webhook_endpoints', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('developer_application_id')->unique()->constrained()->restrictOnDelete();
            $table->string('url', 2048);
            $table->text('signing_secret');
            $table->boolean('enabled')->default(false);
            $table->foreignId('configured_by_user_id')->constrained('users');
            $table->timestamps();
        });
        Schema::create('wallet_webhook_deliveries', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('webhook_endpoint_id')->constrained()->restrictOnDelete();
            $table->foreignUuid('deposit_id')->constrained()->restrictOnDelete();
            $table->uuid('event_id')->unique();
            $table->text('body');
            $table->string('status', 20)->default('pending');
            $table->unsignedInteger('attempts')->default(0);
            $table->timestamp('claimed_at')->nullable();
            $table->uuid('claim_token')->nullable();
            $table->timestamp('next_attempt_at')->nullable();
            $table->timestamp('delivered_at')->nullable();
            $table->string('last_error_code', 40)->nullable();
            $table->timestamps();
            $table->unique(['webhook_endpoint_id', 'deposit_id'], 'wallet_webhook_endpoint_deposit_unique');
            $table->index(['status', 'next_attempt_at']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('wallet_webhook_deliveries');
        Schema::dropIfExists('webhook_endpoints');
    }
};
