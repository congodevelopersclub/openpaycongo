<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('operator_sms_interpretation_requests', function (Blueprint $table): void {
            $table->string('provider', 32)->nullable()->after('sms_record_id');
            $table->string('analysis_status', 24)->default('pending')->index()->after('expires_at');
            $table->uuid('operator_sms_pattern_proposal_id')->nullable()->after('analysis_status');
            $table->foreign('operator_sms_pattern_proposal_id', 'operator_sms_interpretation_proposal_fk')
                ->references('id')->on('operator_sms_pattern_proposals')->restrictOnDelete();
            $table->timestamp('analysis_started_at', 6)->nullable()->after('operator_sms_pattern_proposal_id');
            $table->timestamp('analysed_at', 6)->nullable()->after('analysis_started_at');
            $table->string('analysis_error', 64)->nullable()->after('analysed_at');
        });
    }

    public function down(): void
    {
        Schema::table('operator_sms_interpretation_requests', function (Blueprint $table): void {
            $table->dropForeign('operator_sms_interpretation_proposal_fk');
            $table->dropColumn([
                'provider',
                'analysis_status',
                'operator_sms_pattern_proposal_id',
                'analysis_started_at',
                'analysed_at',
                'analysis_error',
            ]);
        });
    }
};
