<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->char('pairing_secret_digest', 64)->nullable();
            $table->text('server_receive_key')->nullable();
            $table->text('server_send_key')->nullable();
            $table->text('short_authentication_code')->nullable();
        });
        Schema::table('source_installations', function (Blueprint $table): void {
            $table->text('mobile_receive_key')->nullable();
            $table->text('mobile_send_key')->nullable();
            $table->unsignedBigInteger('mobile_replay_counter')->default(0);
        });
    }

    public function down(): void
    {
        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropColumn(['mobile_receive_key', 'mobile_send_key', 'mobile_replay_counter']);
        });
        Schema::table('pairing_intents', function (Blueprint $table): void {
            $table->dropColumn(['pairing_secret_digest', 'server_receive_key', 'server_send_key', 'short_authentication_code']);
        });
    }
};
