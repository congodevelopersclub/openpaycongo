<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsPatternProposal;
use App\Models\Organization;
use App\Models\User;
use App\OperatorSms\Gemma4PaymentPatternAuthor;
use App\OperatorSms\OperatorPaymentPatternReview;
use App\OperatorSms\OperatorPaymentPatternSubmission;
use App\Security\FinancialOperatorMfaSession;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

final class OperatorSmsPatternReviewTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        $this->app->instance(FinancialOperatorMfaSession::class, new class implements FinancialOperatorMfaSession
        {
            public function assertVerified(User $user): void {}
        });
    }

    public function test_gemma_proposal_is_durable_without_retaining_the_raw_sms_and_requires_review_before_activation(): void
    {
        $operator = $this->financialOperator('00000000-0000-4000-8000-000000000401');
        config()->set('services.gemma.private_inference_url', 'http://gemma-inference.internal/v1/chat/completions');
        config()->set('services.gemma.auth_token', 'test-token');

        Http::fake([
            '*' => Http::response([
                'choices' => [[
                    'message' => [
                        'content' => json_encode([
                            'provider' => 'ORANGE_MONEY',
                            'sender' => 'ORANGE',
                            'template' => 'Paid {amount} {currency} ref {reference}',
                        ], JSON_THROW_ON_ERROR),
                    ]],
                ]],
            ]),
        ]);

        $proposal = app(OperatorPaymentPatternReview::class)->propose(
            $operator->organization_id,
            new OperatorPaymentPatternSubmission('ORANGE', 'Paid 12.50 USD ref SECRET-1234', 'ORANGE_MONEY'),
            app(Gemma4PaymentPatternAuthor::class),
        );

        self::assertSame('pending_review', $proposal->status);
        self::assertFalse($proposal->isActivated());
        self::assertArrayNotHasKey('raw_sms', $proposal->getAttributes());
        self::assertStringNotContainsString('SECRET-1234', json_encode($proposal->getAttributes(), JSON_THROW_ON_ERROR));

        $approved = app(OperatorPaymentPatternReview::class)->approve($operator, $proposal);

        self::assertSame('approved', $approved->status);
        self::assertSame($operator->getKey(), $approved->reviewed_by_user_id);
        self::assertNotNull($approved->reviewed_at);
        self::assertFalse($approved->isActivated());
    }

    public function test_an_operator_cannot_review_another_organization_pattern(): void
    {
        $owner = $this->financialOperator('00000000-0000-4000-8000-000000000402');
        $other = $this->financialOperator('00000000-0000-4000-8000-000000000403');
        $proposal = OperatorSmsPatternProposal::query()->create([
            'organization_id' => $owner->organization_id,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'template' => 'Paid {amount} {currency} ref {reference}',
            'template_sha256' => hash('sha256', 'Paid {amount} {currency} ref {reference}'),
            'model' => 'gemma-4-26b-a4b-it',
            'status' => 'pending_review',
        ]);

        $this->expectException(AuthorizationException::class);

        app(OperatorPaymentPatternReview::class)->approve($other, $proposal);
    }

    private function financialOperator(string $organizationId): User
    {
        (new Organization)->forceFill(['id' => $organizationId])->save();

        $user = User::factory()->create();
        $user->forceFill([
            'organization_id' => $organizationId,
            'is_financial_operator' => true,
        ])->save();

        return $user->refresh();
    }
}
