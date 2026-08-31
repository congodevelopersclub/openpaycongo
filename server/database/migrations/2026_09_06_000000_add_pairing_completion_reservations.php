<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->unsignedTinyInteger('invalid_proof_attempts')->default(0);
            $table->binary('completion_request_digest', length: 32, fixed: true)->nullable();
            $table->text('completion_result')->nullable();
        });

        Schema::create('pairing_completion_reservations', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('pairing_intent_id')->index();
            $table->binary('request_digest', length: 32, fixed: true);
            $table->string('state', 24)->index();
            $table->timestamps();

            $table->foreign('pairing_intent_id')->references('id')->on('pairing_intents')->cascadeOnDelete();
            // Parent intent row lock makes active-digest admission atomic. Keep
            // released history repeatable: same client retry may fail more than once.
            $table->index(['pairing_intent_id', 'request_digest', 'state']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pairing_completion_reservations');

        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->dropColumn(['invalid_proof_attempts', 'completion_request_digest', 'completion_result']);
        });
    }
};
