<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->string('intent_nonce', 43)->nullable();
            $table->string('enrollment_signing_public_key', 43)->nullable();
            $table->string('enrollment_signing_fingerprint', 43)->nullable();
            $table->string('server_key_agreement_public_key', 43)->nullable();
            $table->string('trust_mode', 32)->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->dropColumn([
                'intent_nonce',
                'enrollment_signing_public_key',
                'enrollment_signing_fingerprint',
                'server_key_agreement_public_key',
                'trust_mode',
            ]);
        });
    }
};
