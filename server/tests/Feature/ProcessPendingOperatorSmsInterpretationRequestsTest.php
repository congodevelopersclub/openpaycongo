<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsInterpretationRequest;
use App\Models\SourceInstallation;
use App\OperatorSms\ProcessPendingOperatorSmsInterpretationRequests;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Http;
use Tests\TestCase;

final class ProcessPendingOperatorSmsInterpretationRequestsTest extends TestCase
{
    use RefreshDatabase;

    public function test_explicit_evidence_is_decrypted_only_for_private_inference_then_becomes_a_review_only_proposal(): void
    {
        config()->set('services.gemma.private_inference_url', 'http://gemma-inference.internal/v1/chat/completions');
        config()->set('services.gemma.auth_token', 'private-test-token');
        config()->set('services.gemma.model', 'gemma-4-26b-a4b-it');
        config()->set('services.gemma.timeout_seconds', 5);
        Http::fake([
            'http://gemma-inference.internal/v1/chat/completions' => Http::response([
                'choices' => [[
                    'message' => ['content' => json_encode([
                        'provider' => 'ORANGE_MONEY',
                        'sender' => 'ORANGE',
                        'template' => 'Paid {amount} {currency} ref {reference}',
                    ], JSON_THROW_ON_ERROR)],
                ]],
            ]),
        ]);
        $request = $this->request();

        self::assertSame(1, app(ProcessPendingOperatorSmsInterpretationRequests::class)->execute());

        $request->refresh();
        self::assertSame('proposed', $request->analysis_status);
        self::assertNotNull($request->operator_sms_pattern_proposal_id);
        self::assertNotNull($request->analysed_at);
        self::assertDatabaseHas('operator_sms_pattern_proposals', [
            'id' => $request->operator_sms_pattern_proposal_id,
            'organization_id' => $request->organization_id,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'status' => 'pending_review',
        ]);
        self::assertArrayNotHasKey('protected_sms_body', $request->toArray());
        Http::assertSent(function ($request): bool {
            return $request->hasHeader('Authorization', 'Bearer private-test-token')
                && str_contains((string) data_get($request->data(), 'messages.1.content'), 'Paid 12.50 USD ref REF-1234');
        });
    }

    public function test_expired_or_already_analysed_evidence_is_never_sent_to_inference_again(): void
    {
        $expired = $this->request(['expires_at' => now('UTC')->subSecond()]);
        $proposed = $this->request([
            'sms_record_id' => str_repeat('b', 43),
            'analysis_status' => 'proposed',
            'analysed_at' => now('UTC'),
        ]);
        Http::fake();

        self::assertSame(0, app(ProcessPendingOperatorSmsInterpretationRequests::class)->execute());
        Http::assertNothingSent();
        $expired->refresh();
        $proposed->refresh();
        self::assertSame('pending', $expired->analysis_status);
        self::assertSame('proposed', $proposed->analysis_status);
    }

    /** @param array<string, mixed> $overrides */
    private function request(array $overrides = []): OperatorSmsInterpretationRequest
    {
        $installation = SourceInstallation::query()->firstOrCreate(['installation_digest' => hash('sha256', 'operator-sms-analysis')], [
            'id' => '00000000-0000-4000-8000-000000000431',
            'organization_id' => '00000000-0000-4000-8000-000000000401',
            'installation_digest' => hash('sha256', 'operator-sms-analysis'),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000499',
            'installation_key_version' => 'v1',
            'pairing_intent_id' => str_repeat('p', 22),
        ]);

        return OperatorSmsInterpretationRequest::query()->create(array_replace([
            'organization_id' => $installation->organization_id,
            'source_installation_id' => $installation->id,
            'sms_record_id' => str_repeat('a', 43),
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'protected_sms_body' => 'Paid 12.50 USD ref REF-1234',
            'received_at' => now('UTC')->subMinute(),
            'expires_at' => now('UTC')->addDay(),
            'analysis_status' => 'pending',
        ], $overrides));
    }
}
