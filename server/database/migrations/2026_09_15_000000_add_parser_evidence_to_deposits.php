<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->text('parser_evidence')->nullable();
        });
    }

    public function down(): void
    {
        Schema::table('deposits', function (Blueprint $table): void {
            $table->dropColumn('parser_evidence');
        });
    }
};
