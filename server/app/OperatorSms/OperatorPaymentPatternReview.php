<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsPatternProposal;
use App\Models\Organization;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Illuminate\Validation\ValidationException;

/**
 * Creates bounded manual proposals and records the independent MFA review.
 * A proposal remains inert until ReleaseApprovedOperatorPaymentPattern signs it.
 */
final class OperatorPaymentPatternReview
{
    public function __construct(private readonly FinancialOperatorMfaSession $mfaSession) {}

    public function proposeManual(User $actor, string $provider, string $sender, string $template): OperatorSmsPatternProposal
    {
        $organizationId = $this->authorizedOrganizationId($actor);
        $this->mfaSession->assertVerified($actor);
        $provider = trim($provider);
        $sender = trim($sender);

        try {
            OperatorPaymentPatternContract::assertFields($provider, $sender, $template, walletEvidence: true);
        } catch (\InvalidArgumentException) {
            throw ValidationException::withMessages(['pattern' => 'Use canonical provider and sender IDs and a literal template with all five required fields.']);
        }

        return DB::transaction(function () use ($organizationId, $provider, $sender, $template): OperatorSmsPatternProposal {
            // Serialize identical submissions while preserving every earlier approval.
            Organization::query()->lockForUpdate()->findOrFail($organizationId);
            $templateDigest = hash('sha256', $template);
            $latest = OperatorSmsPatternProposal::query()
                ->where('organization_id', $organizationId)
                ->where('provider', $provider)
                ->where('sender', $sender)
                ->where('template_sha256', $templateDigest)
                ->orderByDesc('proposal_revision')
                ->lockForUpdate()
                ->first();

            if ($latest !== null && $latest->status === 'pending_review') {
                return $latest;
            }

            return OperatorSmsPatternProposal::query()->create([
                'organization_id' => $organizationId,
                'provider' => $provider,
                'sender' => $sender,
                'template_sha256' => $templateDigest,
                'proposal_revision' => ($latest->proposal_revision ?? 0) + 1,
                'template' => $template,
                'model' => null,
                'status' => 'pending_review',
            ]);
        });
    }

    public function approve(User $actor, OperatorSmsPatternProposal $proposal): OperatorSmsPatternProposal
    {
        $organizationId = $this->authorizedOrganizationId($actor);
        $this->mfaSession->assertVerified($actor);

        return DB::transaction(function () use ($actor, $organizationId, $proposal): OperatorSmsPatternProposal {
            $proposal = OperatorSmsPatternProposal::query()->lockForUpdate()->findOrFail($proposal->getKey());

            if ($proposal->organization_id !== $organizationId || $proposal->status !== 'pending_review') {
                throw new AuthorizationException;
            }
            if (! OperatorPaymentPatternContract::validTemplate($proposal->template)
                || ! hash_equals($proposal->template_sha256, hash('sha256', $proposal->template))) {
                throw new AuthorizationException;
            }

            $proposal->forceFill([
                'status' => 'approved',
                'reviewed_by_user_id' => $actor->getKey(),
                'reviewed_at' => now('UTC'),
            ])->save();

            return $proposal->refresh();
        });
    }

    private function authorizedOrganizationId(User $actor): string
    {
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id) || ! Str::isUuid($actor->organization_id)) {
            throw new AuthorizationException;
        }

        return $actor->organization_id;
    }
}
