<?php

declare(strict_types=1);

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
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
        if (Schema::getConnection()->getDriverName() === 'sqlite') {
            // SQLite cannot remove a column that is named by a foreign-key
            // definition. Recreate the pre-analysis table instead so historical
            // migration tests exercise the same reversible schema as production.
            Schema::create('operator_sms_interpretation_requests_rollback', function (Blueprint $table): void {
                $table->uuid('id')->primary();
                $table->uuid('organization_id')->index();
                $table->uuid('source_installation_id');
                $table->foreign('source_installation_id', 'operator_sms_interpretation_source_rollback_fk')
                    ->references('id')->on('source_installations')->restrictOnDelete();
                $table->string('sms_record_id', 64);
                $table->string('sender', 16);
                $table->text('protected_sms_body');
                $table->timestamp('received_at', 6);
                $table->timestamp('expires_at', 6)->index();
                $table->timestamps(6);
                $table->unique(
                    ['source_installation_id', 'sms_record_id'],
                    'operator_sms_interpretation_request_rollback_unique',
                );
            });

            $columns = [
                'id',
                'organization_id',
                'source_installation_id',
                'sms_record_id',
                'sender',
                'protected_sms_body',
                'received_at',
                'expires_at',
                'created_at',
                'updated_at',
            ];

            DB::table('operator_sms_interpretation_requests_rollback')->insertUsing(
                $columns,
                DB::table('operator_sms_interpretation_requests')->select($columns),
            );

            Schema::drop('operator_sms_interpretation_requests');
            Schema::rename(
                'operator_sms_interpretation_requests_rollback',
                'operator_sms_interpretation_requests',
            );

            return;
        }

        Schema::table('operator_sms_interpretation_requests', function (Blueprint $table): void {
            $table->dropForeign('operator_sms_interpretation_proposal_fk');
            $table->dropIndex(['analysis_status']);
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
