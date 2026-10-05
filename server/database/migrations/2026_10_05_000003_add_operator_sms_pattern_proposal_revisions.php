<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('operator_sms_pattern_proposals', function (Blueprint $table): void {
            $table->unsignedInteger('proposal_revision')->default(1);
        });

        Schema::table('operator_sms_pattern_proposals', function (Blueprint $table): void {
            $table->dropUnique('operator_sms_pattern_proposals_unique');
            $table->unique(['organization_id', 'provider', 'sender', 'template_sha256', 'proposal_revision'], 'operator_sms_pattern_proposals_unique');
        });
    }

    public function down(): void
    {
        if (DB::table('operator_sms_pattern_proposals')->where('proposal_revision', '>', 1)->exists()) {
            throw new LogicException('Cannot remove parser proposal revisions after renewed proposals exist. Preserve the migration and its review history.');
        }

        Schema::table('operator_sms_pattern_proposals', function (Blueprint $table): void {
            $table->dropUnique('operator_sms_pattern_proposals_unique');
            $table->unique(['organization_id', 'provider', 'sender', 'template_sha256'], 'operator_sms_pattern_proposals_unique');
            $table->dropColumn('proposal_revision');
        });
    }
};
