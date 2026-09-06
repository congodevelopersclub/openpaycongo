<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsPatternProposal;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;

/**
 * Persists review-only pattern proposals. Approval is deliberately not
 * activation: only a subsequent signed release may change mobile parsing.
 */
final class OperatorPaymentPatternReview
{
    public function __construct(private readonly FinancialOperatorMfaSession $mfaSession) {}

    public function propose(
        string $organizationId,
        OperatorPaymentPatternSubmission $submission,
        Gemma4PaymentPatternAuthor $author,
    ): OperatorSmsPatternProposal {
        if (! Str::isUuid($organizationId)) {
            throw new AuthorizationException;
        }

        $candidate = $author->propose($submission);

        return OperatorSmsPatternProposal::query()->firstOrCreate(
            [
                'organization_id' => $organizationId,
                'provider' => $candidate->provider,
                'sender' => $candidate->sender,
                'template_sha256' => hash('sha256', $candidate->template),
            ],
            [
                'template' => $candidate->template,
                'model' => (string) config('services.gemma.model'),
                'status' => 'pending_review',
            ],
        );
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

            $proposal->forceFill([
                'status' => 'approved',
                'reviewed_by_user_id' => $actor->getKey(),
                'reviewed_at' => now(),
            ])->save();

            return $proposal->refresh();
        });
    }

    private function authorizedOrganizationId(User $actor): string
    {
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id)) {
            throw new AuthorizationException;
        }

        return $actor->organization_id;
    }
}
