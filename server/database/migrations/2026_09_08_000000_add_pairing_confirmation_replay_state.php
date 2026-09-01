<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->char('confirmation_request_digest', 64)->nullable();
            $table->string('confirmation_decision', 32)->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->dropColumn(['confirmation_request_digest', 'confirmation_decision']);
        });
    }
};
