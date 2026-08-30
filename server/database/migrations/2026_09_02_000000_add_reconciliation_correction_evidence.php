<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('users', function (Blueprint $table): void {
            $table->boolean('is_financial_operator')->default(false)->index();
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->string('reversal_reason', 255)->nullable();
            $table->foreignId('reversed_by_user_id')->nullable()->constrained('users');
        });

        Schema::table('ledger_entries', function (Blueprint $table): void {
            $table->uuid('reverses_ledger_entry_id')->nullable()->unique();
            $table->foreign('reverses_ledger_entry_id')->references('id')->on('ledger_entries');
        });

        Schema::create('financial_correction_audits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->uuid('deposit_id');
            $table->uuid('organization_id');
            $table->foreignId('actor_user_id')->constrained('users');
            $table->string('correction', 64);
            $table->string('reason', 255);
            $table->dateTime('recorded_at');
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->foreign('deposit_id')->references('id')->on('deposits');
            $table->unique(['deposit_id', 'correction']);
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('financial_correction_audits');

        Schema::table('ledger_entries', function (Blueprint $table): void {
            $table->dropForeign(['reverses_ledger_entry_id']);
            $table->dropUnique(['reverses_ledger_entry_id']);
            $table->dropColumn('reverses_ledger_entry_id');
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropForeign(['reversed_by_user_id']);
            $table->dropColumn(['reversal_reason', 'reversed_by_user_id']);
        });

        Schema::table('users', function (Blueprint $table): void {
            $table->dropIndex(['is_financial_operator']);
            $table->dropColumn('is_financial_operator');
        });
    }
};
