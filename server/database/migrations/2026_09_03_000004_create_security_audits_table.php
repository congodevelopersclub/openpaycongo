<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('security_audits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignId('user_id')->constrained()->cascadeOnDelete();
            $table->string('action', 80);
            $table->timestamp('created_at')->useCurrent();
        });
    }

    public function down(): void
    {
        if (DB::table('security_audits')->exists()) {
            throw new \LogicException('Security audit evidence must be retained.');
        }

        Schema::dropIfExists('security_audits');
    }
};
