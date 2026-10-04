<?php

namespace App\DeveloperApplications;

use App\Deposits\RecordProviderDeposit;
use App\Models\Customer;
use App\Models\DeveloperApplication;
use App\Models\DeveloperCustomerAccess;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Support\Facades\DB;

final readonly class CustomerWalletAccess
{
    public function __construct(private FinancialOperatorMfaSession $mfa, private RecordProviderDeposit $deposits) {}

    public function provision(User $actor, string $applicationId, string $lookupIdentifier): Customer
    {
        abort_unless($actor->is_financial_operator && is_string($actor->organization_id), 403);
        $this->mfa->assertVerified($actor);

        return DB::transaction(function () use ($actor, $applicationId, $lookupIdentifier): Customer {
            DeveloperApplication::query()->whereKey($applicationId)
                ->where('organization_id', $actor->organization_id)->lockForUpdate()->firstOrFail();
            $customer = $this->deposits->registerCustomer($actor->organization_id, $lookupIdentifier);
            $this->change($actor, $applicationId, $customer->id, true);

            return $customer;
        });
    }

    public function customer(DeveloperApplication $application, string $customerId): Customer
    {
        return Customer::query()->whereKey($customerId)
            ->where('organization_id', $application->organization_id)
            ->whereExists(function ($query) use ($application): void {
                $query->selectRaw('1')->from('developer_customer_accesses')
                    ->whereColumn('customer_id', 'customers.id')
                    ->where('developer_application_id', $application->id);
            })->firstOrFail();
    }

    public function change(User $actor, string $applicationId, string $customerId, bool $grant): void
    {
        abort_unless($actor->is_financial_operator && is_string($actor->organization_id), 403);
        $this->mfa->assertVerified($actor);
        DB::transaction(function () use ($actor, $applicationId, $customerId, $grant): void {
            $application = DeveloperApplication::query()->whereKey($applicationId)
                ->where('organization_id', $actor->organization_id)->lockForUpdate()->firstOrFail();
            $customer = Customer::query()->whereKey($customerId)
                ->where('organization_id', $actor->organization_id)->firstOrFail();
            $query = DeveloperCustomerAccess::query()->where('developer_application_id', $application->id)
                ->where('customer_id', $customer->id);
            if ($grant) {
                $query->firstOrCreate([
                    'developer_application_id' => $application->id,
                    'customer_id' => $customer->id,
                ], ['granted_by_user_id' => $actor->id]);
            } else {
                $query->delete();
            }
        });
    }
}
