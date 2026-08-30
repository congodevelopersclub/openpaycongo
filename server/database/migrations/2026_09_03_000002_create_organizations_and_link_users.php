<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('organizations', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->timestamps();
        });

        Schema::table('users', function (Blueprint $table): void {
            $table->string('username')->nullable()->unique()->after('name');
            $table->uuid('organization_id')->nullable()->index()->after('id');
        });
    }

    public function down(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            $table->dropColumn(['organization_id', 'username']);
        });

        Schema::dropIfExists('organizations');
    }
};
