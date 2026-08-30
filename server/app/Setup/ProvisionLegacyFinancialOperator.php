<?php

namespace App\Setup;

use App\Models\InitialSetupState;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Schema;
use LogicException;

final class ProvisionLegacyFinancialOperator
{
    public function provision(int $userId): void
    {
        if (! Schema::hasTable('security_audits')) {
            throw new LogicException('Run all migrations before legacy operator provisioning.');
        }

        DB::transaction(function () use ($userId): void {
            $state = InitialSetupState::query()->lockForUpdate()->findOrFail(1);

            if ($state->completed_at === null) {
                throw new LogicException('Legacy operator provisioning is only available after setup is closed.');
            }

            $user = User::query()->lockForUpdate()->findOrFail($userId);

            if ($user->is_financial_operator || User::query()->where('is_financial_operator', true)->lockForUpdate()->exists()) {
                throw new LogicException('A financial operator is already provisioned.');
            }

            $organizations = Organization::query()->lockForUpdate()->get();

            if ($organizations->count() > 1) {
                throw new LogicException('Legacy organization ownership is ambiguous.');
            }

            $organization = $organizations->first() ?? Organization::query()->create();

            if (User::query()
                ->whereNotNull('organization_id')
                ->where('organization_id', '!=', $organization->getKey())
                ->lockForUpdate()
                ->exists()) {
                throw new LogicException('Legacy organization ownership is ambiguous.');
            }

            $user->organization_id = $organization->getKey();
            $user->is_financial_operator = true;
            $user->save();

            app(RecordSecurityAudit::class)->record($user, 'legacy_financial_operator_provisioned');
        });
    }
}
