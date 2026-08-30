<?php

use Illuminate\Database\Migrations\Migration;
use Illuminate\Database\Schema\Blueprint;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use Illuminate\Support\Str;

return new class extends Migration
{
    public function up(): void
    {
        Schema::create('customer_credits', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('customer_id')->constrained()->cascadeOnDelete();
            $table->string('currency', 3);
            $table->unsignedBigInteger('available_minor');
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->unique(['customer_id', 'currency']);
        });

        Schema::create('payment_requests', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('customer_id')->constrained()->cascadeOnDelete();
            $table->string('currency', 3);
            $table->unsignedBigInteger('amount_minor');
            $table->unsignedBigInteger('remaining_minor');
            $table->string('status', 16);
            $table->dateTime('expires_at');
            $table->dateTime('charged_at')->nullable();
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->index(['customer_id', 'currency', 'status', 'expires_at', 'created_at', 'id'], 'payment_requests_allocation_index');
        });

        Schema::create('customer_credit_postings', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('deposit_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('customer_credit_id')->constrained('customer_credits')->cascadeOnDelete();
            $table->unsignedBigInteger('amount_minor');
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->unique('deposit_id');
        });

        $balances = DB::table('deposits')
            ->join('ledger_entries', 'ledger_entries.deposit_id', '=', 'deposits.id')
            ->where('ledger_entries.account', 'customer_credit')
            ->select('deposits.customer_id', 'ledger_entries.currency')
            ->selectRaw('SUM(ledger_entries.credit_minor - ledger_entries.debit_minor) AS available_minor')
            ->groupBy('deposits.customer_id', 'ledger_entries.currency')
            ->get();

        foreach ($balances as $balance) {
            if ((int) $balance->available_minor > 0) {
                DB::table('customer_credits')->insert([
                    'id' => (string) Str::uuid(),
                    'customer_id' => $balance->customer_id,
                    'currency' => $balance->currency,
                    'available_minor' => $balance->available_minor,
                ]);
            }
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('customer_credit_postings');
        Schema::dropIfExists('payment_requests');
        Schema::dropIfExists('customer_credits');
    }
};
