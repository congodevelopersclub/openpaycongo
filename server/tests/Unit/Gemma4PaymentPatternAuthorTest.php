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
        config()->set('services.gemma.api_key', 'test-key');
        config()->set('services.gemma.model', 'gemma-4-26b-a4b-it');
        config()->set('services.gemma.timeout_seconds', 12);

        Http::fake([
            'https://generativelanguage.googleapis.com/v1beta/models/gemma-4-26b-a4b-it:generateContent*' => Http::response([
                'candidates' => [[
                    'content' => [
                        'parts' => [[
                            'text' => json_encode([
                                'provider' => 'ORANGE_MONEY',
                                'sender' => 'ORANGE',
                                'template' => 'Paid {amount} {currency} ref {reference}',
                            ], JSON_THROW_ON_ERROR),
                        ]],
                    ],
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

            return $request->url() === 'https://generativelanguage.googleapis.com/v1beta/models/gemma-4-26b-a4b-it:generateContent?key=test-key'
                && data_get($payload, 'generationConfig.responseMimeType') === 'application/json'
                && data_get($payload, 'generationConfig.thinkingConfig.thinkingLevel') === 'minimal';
        });
    }

    public function test_it_refuses_malformed_model_output(): void
    {
        config()->set('services.gemma.api_key', 'test-key');

        Http::fake([
            '*' => Http::response([
                'candidates' => [[
                    'content' => ['parts' => [['text' => '{"provider":"ORANGE_MONEY"}']],
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
}
