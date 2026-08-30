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
            $table->bigInteger('available_minor');
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->unique(['customer_id', 'currency']);
        });

        Schema::create('payment_requests', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('customer_id')->constrained()->cascadeOnDelete();
            $table->char('idempotency_digest', 64);
            $table->char('idempotency_key_fingerprint', 64);
            $table->string('currency', 3);
            $table->bigInteger('amount_minor');
            $table->unsignedBigInteger('remaining_minor');
            $table->string('status', 16);
            $table->dateTime('expires_at');
            $table->dateTime('charged_at')->nullable();
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->index(['customer_id', 'currency', 'status', 'expires_at', 'created_at', 'id'], 'payment_requests_allocation_index');
            $table->unique(['customer_id', 'idempotency_digest']);
        });

        Schema::create('customer_credit_postings', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('deposit_id')->constrained()->cascadeOnDelete();
            $table->foreignUuid('customer_credit_id')->constrained('customer_credits')->cascadeOnDelete();
            $table->bigInteger('amount_minor');
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->unique('deposit_id');
        });

        Schema::create('payment_request_allocation_deliveries', function (Blueprint $table): void {
            $table->uuid('id')->primary();
            $table->foreignUuid('payment_request_id')->constrained()->cascadeOnDelete();
            $table->dateTime('claimed_at')->nullable();
            $table->uuid('claim_token')->nullable();
            $table->dateTime('dispatched_at')->nullable();
            $table->dateTime('created_at')->nullable();
            $table->dateTime('updated_at')->nullable();
            $table->unique('payment_request_id');
        });

        // Balance and marker are derived from the same row and committed together.
        // A deposit outside this cursor snapshot receives neither, so the scheduled
        // recovery command can still identify and reconcile it after deployment.
        $postings = DB::table('deposits')
            ->join('ledger_entries', 'ledger_entries.deposit_id', '=', 'deposits.id')
            ->where('ledger_entries.account', 'customer_credit')
            ->select('deposits.id', 'deposits.customer_id', 'ledger_entries.currency')
            ->selectRaw('SUM(ledger_entries.credit_minor) AS credited_minor, SUM(ledger_entries.debit_minor) AS debited_minor')
            ->groupBy('deposits.id', 'deposits.customer_id', 'ledger_entries.currency')
            ->orderBy('deposits.id')
            ->cursor();

        foreach ($postings as $posting) {
            DB::transaction(function () use ($posting): void {
                DB::table('customer_credits')->insertOrIgnore([
                    'id' => (string) Str::uuid(),
                    'customer_id' => $posting->customer_id,
                    'currency' => $posting->currency,
                    'available_minor' => 0,
                ]);
                $creditId = DB::table('customer_credits')
                    ->where('customer_id', $posting->customer_id)
                    ->where('currency', $posting->currency)
                    ->value('id');
                $amountMinor = (int) $posting->credited_minor - (int) $posting->debited_minor;
                $inserted = DB::table('customer_credit_postings')->insertOrIgnore([
                    'id' => (string) Str::uuid(),
                    'deposit_id' => $posting->id,
                    'customer_credit_id' => $creditId,
                    'amount_minor' => $amountMinor,
                ]);
                if ($inserted === 1 && $amountMinor !== 0) {
                    DB::table('customer_credits')->where('id', $creditId)->increment('available_minor', $amountMinor);
                }
            });
        }
    }

    public function down(): void
    {
        Schema::dropIfExists('payment_request_allocation_deliveries');
        Schema::dropIfExists('customer_credit_postings');
        Schema::dropIfExists('payment_requests');
        Schema::dropIfExists('customer_credits');
    }
};
