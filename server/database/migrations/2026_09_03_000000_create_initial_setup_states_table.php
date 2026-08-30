<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('initial_setup_states', function (Blueprint $table): void {
            $table->unsignedTinyInteger('id')->primary();
            $table->dateTime('completed_at')->nullable();
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
        });

        DB::table('initial_setup_states')->insert([
            'id' => 1,
            'created_at' => now(),
            'updated_at' => now(),
        ]);
    }

    public function down(): void
    {
        if (DB::table('initial_setup_states')->whereNotNull('completed_at')->exists()) {
            throw new LogicException('Completed initial setup cannot be removed.');
        }

        Schema::dropIfExists('initial_setup_states');
    }
};
