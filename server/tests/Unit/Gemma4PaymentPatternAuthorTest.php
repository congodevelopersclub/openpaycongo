<?php

declare(strict_types=1);

namespace Tests\Unit;

use App\OperatorSms\Gemma4PaymentPatternAuthor;
use App\OperatorSms\OperatorPaymentPatternSubmission;
use Illuminate\Http\Client\Request;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

final class Gemma4PaymentPatternAuthorTest extends TestCase
{
    public function test_it_returns_a_strict_candidate_without_activating_it(): void
    {
        config()->set('services.gemma.private_inference_url', 'http://gemma-inference.internal/v1/chat/completions');
        config()->set('services.gemma.auth_token', 'test-token');
        config()->set('services.gemma.model', 'gemma-4-26b-a4b-it');
        config()->set('services.gemma.timeout_seconds', 12);

        Http::fake([
            'http://gemma-inference.internal/v1/chat/completions' => Http::response([
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

        $candidate = app(Gemma4PaymentPatternAuthor::class)->propose(
            new OperatorPaymentPatternSubmission(
                sender: 'ORANGE',
                body: 'Paid 12.50 USD ref REF-1234',
                provider: 'ORANGE_MONEY',
            ),
        );

        self::assertSame('ORANGE_MONEY', $candidate->provider);
        self::assertSame('ORANGE', $candidate->sender);
        self::assertSame('Paid {amount} {currency} ref {reference}', $candidate->template);
        self::assertFalse($candidate->isApproved());
        Http::assertSent(static function (Request $request): bool {
            $payload = $request->data();

            return $request->url() === 'http://gemma-inference.internal/v1/chat/completions'
                && $request->hasHeader('Authorization', 'Bearer test-token')
                && data_get($payload, 'model') === 'gemma-4-26b-a4b-it'
                && data_get($payload, 'response_format.type') === 'json_object'
                && data_get($payload, 'messages.0.role') === 'system'
                && data_get($payload, 'messages.1.role') === 'user';
        });
    }

    public function test_it_refuses_malformed_model_output(): void
    {
        config()->set('services.gemma.private_inference_url', 'http://gemma-inference.internal/v1/chat/completions');
        config()->set('services.gemma.auth_token', 'test-token');

        Http::fake([
            '*' => Http::response([
                'choices' => [[
                    'message' => ['content' => '{"provider":"ORANGE_MONEY"}'],
                ]],
            ]),
        ]);

        $this->expectExceptionMessage('gemma_pattern_candidate_invalid');

        app(Gemma4PaymentPatternAuthor::class)->propose(
            new OperatorPaymentPatternSubmission(
                sender: 'ORANGE',
                body: 'Paid 12.50 USD ref REF-1234',
                provider: 'ORANGE_MONEY',
            ),
        );
    }

    public function test_it_refuses_a_public_inference_endpoint_before_raw_sms_can_leave_the_backend(): void
    {
        config()->set('services.gemma.private_inference_url', 'https://generativelanguage.googleapis.com/v1beta/models/gemma-4-26b-a4b-it:generateContent');
        config()->set('services.gemma.auth_token', 'test-token');

        $this->expectExceptionMessage('gemma_pattern_author_unavailable');

        app(Gemma4PaymentPatternAuthor::class)->propose(
            new OperatorPaymentPatternSubmission(
                sender: 'ORANGE',
                body: 'Paid 12.50 USD ref REF-1234',
                provider: 'ORANGE_MONEY',
            ),
        );
    }
}
