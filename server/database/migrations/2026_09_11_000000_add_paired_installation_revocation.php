<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('source_installations', function (Blueprint $table): void {
            $table->timestamp('revoked_at')->nullable()->index();
        });

        Schema::create('paired_installation_revocation_audits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id')->index('paired_installation_revocation_audits_org_idx');
            $table->uuid('source_installation_id')->index('paired_installation_revocation_audits_installation_idx');
            $table->foreignId('actor_user_id')->nullable()->constrained('users')->nullOnDelete();
            $table->string('actor_user_identifier', 64);
            $table->string('action', 32);
            $table->timestamp('created_at', 6)->useCurrent();
        });
    }

    public function down(): void
    {
        if (DB::table('paired_installation_revocation_audits')->exists()) {
            throw new LogicException('Paired installation revocation audit evidence must be retained.');
        }

        Schema::dropIfExists('paired_installation_revocation_audits');

        Schema::table('source_installations', function (Blueprint $table): void {
            $table->dropIndex('source_installations_revoked_at_index');
            $table->dropColumn('revoked_at');
        });
    }
};
