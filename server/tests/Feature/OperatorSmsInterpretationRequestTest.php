<?php

declare(strict_types=1);

namespace Tests\Feature;

use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class OperatorSmsInterpretationRequestTest extends TestCase
{
    use RefreshDatabase;

    public function test_plaintext_sms_interpretation_endpoint_is_not_exposed(): void
    {
        $payload = [
            'record_id' => str_repeat('r', 43),
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'sms_body' => 'Paid 12.50 USD ref REF-1234',
            'received_at' => '2026-09-06T01:00:00Z',
        ];

        $this->postJson('/mobile/operator-sms/interpretation-requests', $payload)
            ->assertNotFound();
        self::assertDatabaseCount('operator_sms_interpretation_requests', 0);
    }
}
