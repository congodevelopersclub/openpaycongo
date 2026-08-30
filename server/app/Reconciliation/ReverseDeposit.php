<?php

namespace App\Reconciliation;

use App\Deposits\RecordProviderDeposit;
use App\Deposits\ReverseProviderDepositResult;
use App\Models\Deposit;
use App\Models\FinancialCorrectionAudit;
use App\Models\User;
use Carbon\CarbonImmutable;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Gate;
use Illuminate\Validation\ValidationException;

final class ReverseDeposit
{
    public function __construct(private readonly RecordProviderDeposit $deposits) {}

    public function reverse(User $actor, Deposit $deposit, string $reason): ReverseProviderDepositResult
    {
        Gate::forUser($actor)->authorize('correct', $deposit);
        if (trim($reason) === '' || mb_strlen($reason) > 255) {
            throw ValidationException::withMessages(['reason' => 'A bounded correction reason is required.']);
        }

        return DB::transaction(function () use ($actor, $deposit, $reason): ReverseProviderDepositResult {
            $result = $this->deposits->reverse($deposit, $actor, trim($reason));
            FinancialCorrectionAudit::query()->firstOrCreate(
                ['deposit_id' => $result->deposit->id, 'correction' => 'reverse_deposit'],
                [
                    'organization_id' => $result->deposit->organization_id,
                    'actor_user_id' => $actor->id,
                    'reason' => trim($reason),
                    'recorded_at' => CarbonImmutable::now(),
                ],
            );

            return $result;
        });
    }
}
