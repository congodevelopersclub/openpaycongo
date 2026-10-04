<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\Schema;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('developer_customer_accesses', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('developer_application_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('customer_id')->constrained()->cascadeOnDelete();
            $table->foreignId('granted_by_user_id')->constrained('users');
            $table->timestamps();
            $table->unique(['developer_application_id', 'customer_id'], 'developer_customer_access_unique');
        });
    }

    public function down(): void
    {
        Schema::dropIfExists('developer_customer_accesses');
    }
};
