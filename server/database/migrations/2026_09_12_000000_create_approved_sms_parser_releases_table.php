<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('approved_sms_parser_releases', function (Blueprint $table): void {
            $table->char('release_id', 64)->primary();
            $table->string('provider', 128);
            $table->string('sender', 16);
            $table->text('template');
            $table->unsignedInteger('pattern_version');
            $table->dateTime('approved_at');
            $table->dateTime('expires_at');
            $table->string('signature', 128);
            $table->string('signing_public_key', 64);
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->index(['provider', 'sender', 'pattern_version', 'expires_at'], 'sms_parser_release_lookup');
            $table->unique(['provider', 'sender', 'pattern_version'], 'sms_parser_release_version_unique');
        });

        Schema::create('sms_parser_release_scopes', function (Blueprint $table): void {
            $table->char('scope_id', 64)->primary();
            $table->string('provider', 32);
            $table->string('sender', 16);
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
        });

        Schema::table('deposits', function (Blueprint $table): void {
            $table->text('parser_evidence')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropColumn('parser_evidence');
        });
        Schema::dropIfExists('sms_parser_release_scopes');
        Schema::dropIfExists('approved_sms_parser_releases');
    }
};
