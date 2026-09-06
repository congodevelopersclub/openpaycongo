<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsInterpretationRequest;
use App\Models\SourceInstallation;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\DB;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class OperatorSmsInterpretationRequestTest extends TestCase
{
    use RefreshDatabase;

    public function test_an_acknowledged_installation_explicitly_submits_encrypted_sms_evidence_once_for_pattern_review(): void
    {
        $installation = $this->installation('00000000-0000-4000-8000-000000000411');
        $payload = [
            'record_id' => str_repeat('r', 43),
            'sender' => 'ORANGE',
            'sms_body' => 'Paid 12.50 USD ref REF-1234',
            'received_at' => '2026-09-06T01:00:00Z',
        ];

        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');

        $response = $this->postJson('/mobile/operator-sms/interpretation-requests', $payload)
            ->assertStatus(202)
            ->assertJsonPath('outcome', 'accepted_for_pattern_review')
            ->assertHeader('cache-control', 'no-store, private');

        $request = OperatorSmsInterpretationRequest::query()->sole();
        self::assertSame($installation->organization_id, $request->organization_id);
        self::assertSame($installation->id, $request->source_installation_id);
        self::assertSame($payload['sms_body'], $request->protected_sms_body);
        self::assertGreaterThan(now('UTC'), $request->expires_at);
        self::assertArrayNotHasKey('protected_sms_body', $request->toArray());
        self::assertSame($request->id, $response->json('request_id'));
        self::assertStringNotContainsString(
            $payload['sms_body'],
            (string) DB::table('operator_sms_interpretation_requests')->value('protected_sms_body'),
        );

        $this->postJson('/mobile/operator-sms/interpretation-requests', $payload)
            ->assertOk()
            ->assertExactJson([
                'outcome' => 'replayed',
                'request_id' => $request->id,
            ]);
        self::assertDatabaseCount('operator_sms_interpretation_requests', 1);
    }

    public function test_automatic_or_invalid_submission_cannot_store_sms_evidence(): void
    {
        $installation = $this->installation('00000000-0000-4000-8000-000000000412', acknowledged: false);
        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');

        $this->postJson('/mobile/operator-sms/interpretation-requests', [
            'record_id' => str_repeat('r', 43),
            'sender' => 'ORANGE',
            'sms_body' => 'Paid 12.50 USD ref REF-1234',
            'received_at' => '2026-09-06T01:00:00Z',
        ])->assertNotFound()
            ->assertExactJson(['code' => 'mobile_envelope_unavailable']);

        $installation->forceFill(['activation_acknowledged_at' => now('UTC')])->save();
        Sanctum::actingAs($installation, ['mobile:sync:read'], 'mobile');
        $this->postJson('/mobile/operator-sms/interpretation-requests', [])
            ->assertForbidden();

        Sanctum::actingAs($installation, ['mobile:sync:write'], 'mobile');
        $this->postJson('/mobile/operator-sms/interpretation-requests', [
            'record_id' => 'too-short',
            'sender' => 'untrusted sender',
            'sms_body' => '',
            'received_at' => '2026-02-30T01:00:00Z',
        ])->assertUnprocessable()
            ->assertJsonValidationErrors(['record_id', 'sender', 'sms_body', 'received_at']);

        self::assertDatabaseCount('operator_sms_interpretation_requests', 0);
    }

    private function installation(string $id, bool $acknowledged = true): SourceInstallation
    {
        $installation = SourceInstallation::query()->create([
            'id' => $id,
            'organization_id' => '00000000-0000-4000-8000-000000000401',
            'installation_digest' => hash('sha256', $id),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000499',
            'installation_key_version' => 'v1',
            'pairing_intent_id' => str_repeat('p', 22),
        ]);
        if ($acknowledged) {
            $installation->forceFill(['activation_acknowledged_at' => now('UTC')])->save();
        }

        return $installation;
    }
}
