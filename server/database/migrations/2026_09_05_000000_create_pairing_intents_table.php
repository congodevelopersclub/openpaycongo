<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('pairing_intents', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id')->index();
            $table->string('intent_id', 22)->index();
            $table->binary('intent_id_bytes', length: 16, fixed: true)->unique();
            $table->string('state', 32)->index();
            $table->timestamp('expires_at')->index();
            $table->text('protected_server_private_material');
            $table->timestamps();
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('pairing_intents');
    }
};
