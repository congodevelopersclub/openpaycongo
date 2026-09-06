<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use LogicException;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('developer_applications', function (Blueprint $table): void {
            $table->string('name', 120)->nullable()->after('organization_id');
        });

        Schema::table('oauth_clients', function (Blueprint $table): void {
            $table->timestamp('last_used_at')->nullable()->after('scopes');
        });

        Schema::create('developer_application_credential_audits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('organization_id')->index();
            $table->uuid('developer_application_id')->index();
            $table->uuid('oauth_client_id')->index();
            $table->foreignId('actor_user_id')->nullable()->constrained('users')->nullOnDelete();
            $table->string('actor_user_identifier', 64);
            $table->string('action', 32);
            $table->json('scopes');
            $table->unsignedBigInteger('organization_sequence');
            $table->timestamp('created_at', 6)->useCurrent();
            $table->unique(['organization_id', 'organization_sequence']);
        });
    }

    public function down(): void
    {
        if (DB::table('developer_application_credential_audits')->exists()) {
            throw new LogicException('Developer application credential audit evidence must be retained.');
        }

        Schema::dropIfExists('developer_application_credential_audits');

        Schema::table('oauth_clients', function (Blueprint $table): void {
            $table->dropColumn('last_used_at');
        });

        Schema::table('developer_applications', function (Blueprint $table): void {
            $table->dropColumn('name');
        });
    }
};
