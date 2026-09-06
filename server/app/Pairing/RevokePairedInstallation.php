<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\Organization;
use App\Models\PairedInstallationRevocationAudit;
use App\Models\SourceInstallation;
use App\Models\User;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Support\Facades\DB;

final class RevokePairedInstallation
{
    public function revoke(User $actor, string $installationId): void
    {
        $organizationId = $this->organizationId($actor);

        DB::transaction(function () use ($actor, $organizationId, $installationId): void {
            $installation = SourceInstallation::query()
                ->lockForUpdate()
                ->whereKey($installationId)
                ->where('organization_id', $organizationId)
                ->first();

            if (! $installation instanceof SourceInstallation || ! is_string($installation->pairing_intent_id)) {
                throw new AuthorizationException;
            }

            $this->revokeLocked($actor, $installation, 'revoked');
        });
    }

    public function revokeActiveForRotation(User $actor, string $organizationId): void
    {
        if ($this->organizationId($actor) !== $organizationId) {
            throw new AuthorizationException;
        }

        Organization::query()->whereKey($organizationId)->lockForUpdate()->firstOrFail();

        $installations = SourceInstallation::query()
            ->lockForUpdate()
            ->where('organization_id', $organizationId)
            ->whereNotNull('pairing_intent_id')
            ->whereNull('revoked_at')
            ->get();

        foreach ($installations as $installation) {
            $this->revokeLocked($actor, $installation, 'rotated');
        }
    }

    private function revokeLocked(User $actor, SourceInstallation $installation, string $action): void
    {
        if ($installation->revoked_at !== null) {
            return;
        }

        $installation->tokens()->delete();
        $installation->forceFill([
            'mobile_receive_key' => null,
            'mobile_send_key' => null,
            'activation_nonce' => null,
            'activation_ciphertext' => null,
            'revoked_at' => now('UTC'),
        ])->save();

        PairedInstallationRevocationAudit::query()->create([
            'organization_id' => $installation->organization_id,
            'source_installation_id' => $installation->getKey(),
            'actor_user_id' => $actor->getKey(),
            'actor_user_identifier' => (string) $actor->getAuthIdentifier(),
            'action' => $action,
        ]);
    }

    private function organizationId(User $actor): string
    {
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id)) {
            throw new AuthorizationException;
        }

        return $actor->organization_id;
    }
}
