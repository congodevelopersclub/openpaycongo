<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsPatternProposal;
use App\Models\Organization;
use App\Models\User;
use App\OperatorSms\ReleaseApprovedOperatorPaymentPattern;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class ReleaseApprovedOperatorPaymentPatternTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
        config()->set('openpay.operator_sms_patterns.signing_secret', $this->base64Url(str_repeat("\x01", 32)));
    }

    public function test_an_approved_pattern_becomes_a_signed_mobile_release_without_raw_sms(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000404');
        $proposal = $this->approvedProposal($operator);
        $expiresAt = CarbonImmutable::now('UTC')->addDays(30)->startOfSecond();

        $release = app(ReleaseApprovedOperatorPaymentPattern::class)->release($operator, $proposal, $expiresAt);

        self::assertSame(1, $release->pattern_version);
        self::assertSame($proposal->getKey(), $release->operator_sms_pattern_proposal_id);
        self::assertSame($operator->getKey(), $release->issued_by_user_id);
        self::assertSame($expiresAt->format('Y-m-d\\TH:i:s\\Z'), $release->expires_at->format('Y-m-d\\TH:i:s\\Z'));
        self::assertStringNotContainsString('SECRET-1234', $release->encoded_release);

        $payload = json_decode($release->encoded_release, true, 512, JSON_THROW_ON_ERROR);
        self::assertSame([
            'schema_version', 'provider', 'sender', 'template', 'pattern_version', 'approved_at', 'expires_at', 'signature',
        ], array_keys($payload));
        self::assertTrue(sodium_crypto_sign_verify_detached(
            $this->base64UrlDecode($payload['signature']),
            $this->transcript($payload),
            sodium_crypto_sign_publickey(sodium_crypto_sign_seed_keypair(str_repeat("\x01", 32))),
        ));
    }

    public function test_a_pending_or_cross_organization_proposal_cannot_be_released(): void
    {
        $owner = $this->financialOperator('00000000-0000-4000-8000-000000000405');
        $other = $this->financialOperator('00000000-0000-4000-8000-000000000406');
        $pending = $this->proposal($owner, 'pending_review');

        $this->expectException(AuthorizationException::class);

        app(ReleaseApprovedOperatorPaymentPattern::class)->release(
            $other,
            $pending,
            CarbonImmutable::now('UTC')->addDay()->startOfSecond(),
        );
    }

    private function financialOperator(string $organizationId): User
    {
        (new Organization)->forceFill(['id' => $organizationId])->save();
        $user = User::factory()->create();
        $user->forceFill(['organization_id' => $organizationId, 'is_financial_operator' => true])->save();

        return $user->refresh();
    }

    private function approvedProposal(User $operator): OperatorSmsPatternProposal
    {
        return $this->proposal($operator, 'approved', CarbonImmutable::now('UTC')->subMinute()->startOfSecond());
    }

    private function proposal(User $operator, string $status, ?CarbonImmutable $reviewedAt = null): OperatorSmsPatternProposal
    {
        return OperatorSmsPatternProposal::query()->create([
            'organization_id' => $operator->organization_id,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'template' => 'Paid {amount} {currency} ref {reference}',
            'template_sha256' => hash('sha256', 'Paid {amount} {currency} ref {reference}'),
            'model' => 'gemma-4-26b-a4b-it',
            'status' => $status,
            'reviewed_by_user_id' => $reviewedAt === null ? null : $operator->getKey(),
            'reviewed_at' => $reviewedAt,
        ]);
    }

    /** @param array{schema_version: string, provider: string, sender: string, template: string, pattern_version: int, approved_at: string, expires_at: string, signature: string} $release */
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

    private function base64Url(string $bytes): string
    {
        return rtrim(strtr(base64_encode($bytes), '+/', '-_'), '=');
    }

    private function base64UrlDecode(string $value): string
    {
        return base64_decode(strtr($value, '-_', '+/'), true) ?: '';
    }
}
