<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsInterpretationRequest;
use App\Models\SourceInstallation;
use App\OperatorSms\PurgeExpiredOperatorSmsInterpretationRequests;
use Carbon\CarbonImmutable;
use DateTimeInterface;
use Illuminate\Console\Scheduling\Schedule;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Tests\TestCase;

final class PurgeExpiredOperatorSmsInterpretationRequestsTest extends TestCase
{
    use RefreshDatabase;

    public function test_expired_raw_sms_evidence_is_destroyed_but_unexpired_evidence_is_retained(): void
    {
        $now = CarbonImmutable::parse('2026-09-06 12:00:00 UTC');
        CarbonImmutable::setTestNow($now);

        try {
            $expired = $this->request('expired', $now->subSecond());
            $current = $this->request('current', $now);
            $future = $this->request('future', $now->addSecond());

            self::assertSame(2, app(PurgeExpiredOperatorSmsInterpretationRequests::class)->execute());
            self::assertNull($expired->fresh());
            self::assertNull($current->fresh());
            self::assertNotNull($future->fresh());
        } finally {
            CarbonImmutable::setTestNow();
        }
    }

    public function test_command_and_minute_schedule_perform_bounded_evidence_destruction(): void
    {
        $this->request('expired', now('UTC')->subSecond());

        $this->artisan('operator-sms:purge-expired-interpretation-requests')
            ->expectsOutput('Purged 1 expired operator SMS interpretation request(s).')
            ->assertExitCode(0);

        $event = collect(app(Schedule::class)->events())
            ->first(fn ($event): bool => str_contains($event->command, 'operator-sms:purge-expired-interpretation-requests'));
        self::assertNotNull($event);
        self::assertSame('* * * * *', $event->expression);
        self::assertTrue($event->withoutOverlapping);
    }

    private function request(string $suffix, DateTimeInterface $expiresAt): OperatorSmsInterpretationRequest
    {
        $installation = SourceInstallation::query()->firstOrCreate(
            ['organization_id' => '00000000-0000-4000-8000-000000000501'],
            [
                'installation_digest' => hash('sha256', 'operator-sms-purge'),
            ],
        );

        return OperatorSmsInterpretationRequest::query()->create([
            'organization_id' => $installation->organization_id,
            'source_installation_id' => $installation->id,
            'sms_record_id' => str_pad($suffix, 8, 'x'),
            'sender' => 'ORANGE',
            'protected_sms_body' => 'test-only evidence '.$suffix,
            'received_at' => CarbonImmutable::instance($expiresAt)->subMinute(),
            'expires_at' => $expiresAt,
        ]);
    }
}
