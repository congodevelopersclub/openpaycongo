<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('source_installations', function (Blueprint $table): void {
            $table->char('pairing_intent_id', 22)->nullable();
            $table->text('activation_nonce')->nullable();
            $table->text('activation_ciphertext')->nullable();
            $table->unique('pairing_intent_id', 'source_installations_pairing_intent_id_unique');
        });
    }

    public function down(): void
    {
        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropUnique('source_installations_pairing_intent_id_unique');
            $table->dropColumn(['pairing_intent_id', 'activation_nonce', 'activation_ciphertext']);
        });
    }
};
