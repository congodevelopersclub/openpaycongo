<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsPatternProposal;
use App\Models\OperatorSmsPatternRelease;
use App\Models\Organization;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use DateTimeInterface;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Support\Facades\DB;

/**
 * The only authority boundary that turns a reviewed Gemma proposal into mobile
 * parser input. It signs an exact, versioned payload and never stores raw SMS.
 */
final class ReleaseApprovedOperatorPaymentPattern
{
    public function __construct(private readonly FinancialOperatorMfaSession $mfaSession) {}

    public function release(
        User $actor,
        OperatorSmsPatternProposal $proposal,
        DateTimeInterface $expiresAt,
    ): OperatorSmsPatternRelease {
        $organizationId = $this->authorizedOrganizationId($actor);
        $this->mfaSession->assertVerified($actor);
        $expiresAt = CarbonImmutable::instance($expiresAt)->utc();
        $issuedAt = CarbonImmutable::now('UTC')->startOfSecond();

        if ($expiresAt->microsecond !== 0 || ! $expiresAt->isAfter($issuedAt)) {
            throw new AuthorizationException;
        }

        return DB::transaction(function () use ($actor, $organizationId, $proposal, $expiresAt, $issuedAt): OperatorSmsPatternRelease {
            // This serializes version allocation across different approved proposals
            // for one organization without relying on database-specific gap locks.
            Organization::query()->lockForUpdate()->findOrFail($organizationId);
            $proposal = OperatorSmsPatternProposal::query()->lockForUpdate()->findOrFail($proposal->getKey());

            if ($proposal->organization_id !== $organizationId || $proposal->status !== 'approved' || $proposal->reviewed_at === null) {
                throw new AuthorizationException;
            }

            $existing = OperatorSmsPatternRelease::query()
                ->where('operator_sms_pattern_proposal_id', $proposal->getKey())
                ->lockForUpdate()
                ->first();
            if ($existing !== null) {
                return $existing;
            }

            $version = ((int) OperatorSmsPatternRelease::query()
                ->where('organization_id', $organizationId)
                ->where('provider', $proposal->provider)
                ->where('sender', $proposal->sender)
                ->max('pattern_version')) + 1;
            $approvedAt = CarbonImmutable::parse($proposal->reviewed_at, 'UTC')->startOfSecond();
            if (! $expiresAt->isAfter($approvedAt)) {
                throw new AuthorizationException;
            }

            $release = [
                'schema_version' => '1',
                'provider' => $proposal->provider,
                'sender' => $proposal->sender,
                'template' => $proposal->template,
                'pattern_version' => $version,
                'approved_at' => $approvedAt->format('Y-m-d\\TH:i:s\\Z'),
                'expires_at' => $expiresAt->format('Y-m-d\\TH:i:s\\Z'),
            ];
            $release['signature'] = $this->base64Url(sodium_crypto_sign_detached(
                $this->transcript($release),
                sodium_crypto_sign_secretkey(sodium_crypto_sign_seed_keypair($this->signingSeed())),
            ));

            return OperatorSmsPatternRelease::query()->create([
                'operator_sms_pattern_proposal_id' => $proposal->getKey(),
                'organization_id' => $organizationId,
                'provider' => $proposal->provider,
                'sender' => $proposal->sender,
                'pattern_version' => $version,
                'encoded_release' => json_encode($release, JSON_THROW_ON_ERROR),
                'expires_at' => $expiresAt,
                'issued_by_user_id' => $actor->getKey(),
                'issued_at' => $issuedAt,
            ]);
        });
    }

    /** @param array{schema_version: string, provider: string, sender: string, template: string, pattern_version: int, approved_at: string, expires_at: string} $release */
    private function transcript(array $release): string
    {
        return implode('', array_map(
            static fn (string $field): string => pack('n', strlen($field)).$field,
            [
                'openpaycongo/operator-payment-pattern', $release['schema_version'], $release['provider'], $release['sender'],
                $release['template'], (string) $release['pattern_version'], $release['approved_at'], $release['expires_at'],
            ],
        ));
    }

    private function signingSeed(): string
    {
        $encoded = config('openpay.operator_sms_patterns.signing_secret');
        if (! is_string($encoded) || ! preg_match('/^[A-Za-z0-9_-]{43}$/', $encoded)) {
            throw new \InvalidArgumentException('Invalid operator SMS pattern signing configuration.');
        }

        $seed = base64_decode(strtr($encoded, '-_', '+/'), true);
        if (! is_string($seed) || strlen($seed) !== SODIUM_CRYPTO_SIGN_SEEDBYTES || $this->base64Url($seed) !== $encoded) {
            throw new \InvalidArgumentException('Invalid operator SMS pattern signing configuration.');
        }

        return $seed;
    }

    private function authorizedOrganizationId(User $actor): string
    {
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id)) {
            throw new AuthorizationException;
        }

        return $actor->organization_id;
    }

    private function base64Url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }
}
