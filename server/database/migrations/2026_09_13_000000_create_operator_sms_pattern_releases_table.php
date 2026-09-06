<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('operator_sms_pattern_releases', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('operator_sms_pattern_proposal_id');
            $table->foreign('operator_sms_pattern_proposal_id', 'operator_sms_pattern_release_proposal_fk')
                ->references('id')
                ->on('operator_sms_pattern_proposals')
                ->restrictOnDelete();
            $table->uuid('organization_id')->index();
            $table->string('provider', 32);
            $table->string('sender', 64);
            $table->unsignedInteger('pattern_version');
            $table->text('encoded_release');
            $table->timestamp('expires_at', 6);
            $table->foreignId('issued_by_user_id')->constrained('users')->restrictOnDelete();
            $table->timestamp('issued_at', 6);

            $table->unique(['organization_id', 'provider', 'sender', 'pattern_version'], 'operator_sms_pattern_release_version_unique');
            $table->unique('operator_sms_pattern_proposal_id', 'operator_sms_pattern_release_proposal_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('operator_sms_pattern_releases');
    }
};
