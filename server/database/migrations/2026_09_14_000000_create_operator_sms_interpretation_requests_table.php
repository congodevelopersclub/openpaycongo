<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('operator_sms_interpretation_requests', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id')->index();
            $table->uuid('source_installation_id');
            $table->foreign('source_installation_id', 'operator_sms_interpretation_source_fk')
                ->references('id')
                ->on('source_installations')
                ->restrictOnDelete();
            $table->string('sms_record_id', 64);
            $table->string('sender', 16);
            $table->text('protected_sms_body');
            $table->timestamp('received_at', 6);
            $table->timestamp('expires_at', 6)->index();
            $table->timestamps(6);
            $table->unique(['source_installation_id', 'sms_record_id'], 'operator_sms_interpretation_request_record_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('operator_sms_interpretation_requests');
    }
};
