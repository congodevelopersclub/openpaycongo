<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('operator_sms_pattern_proposals', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id')->index();
            $table->string('provider', 32);
            $table->string('sender', 64);
            $table->string('template', 512);
            $table->char('template_sha256', 64);
            $table->string('model', 64)->nullable();
            $table->string('status', 24)->index();
            $table->foreignId('reviewed_by_user_id')->nullable()->constrained('users')->nullOnDelete();
            $table->timestamp('reviewed_at', 6)->nullable();
            $table->timestamps(6);
            $table->unique(['organization_id', 'provider', 'sender', 'template_sha256'], 'operator_sms_pattern_proposals_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('operator_sms_pattern_proposals');
    }
};
