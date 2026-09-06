<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\Models\OperatorSmsPatternProposal;
use App\Models\OperatorSmsPatternRelease;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Laravel\Sanctum\Sanctum;
use Tests\TestCase;

final class OperatorSmsPatternReleaseDeliveryTest extends TestCase
{
    use RefreshDatabase;

    public function test_an_acknowledged_installation_receives_only_its_unexpired_signed_pattern_releases_without_sms_evidence(): void
    {
        $installation = $this->installation('00000000-0000-4000-8000-000000000701');
        $visible = $this->release($installation->organization_id, 'visible-release', now('UTC')->addDay(), 1);
        $this->release($installation->organization_id, 'expired-release', now('UTC')->subSecond(), 2);
        $otherOrganization = '00000000-0000-4000-8000-000000000702';
        $this->release($otherOrganization, 'other-release', now('UTC')->addDay(), 1);

        Sanctum::actingAs($installation, ['mobile:sync:read'], 'mobile');

        $this->getJson('/mobile/operator-sms/pattern-releases')
            ->assertOk()
            ->assertHeader('cache-control', 'no-store, private')
            ->assertExactJson([
                'releases' => [[
                    'release_id' => $visible->id,
                    'encoded_release' => 'visible-release',
                ]],
            ]);
    }

    private function installation(string $organizationId): SourceInstallation
    {
        (new Organization)->forceFill(['id' => $organizationId])->save();

        $installation = SourceInstallation::query()->create([
            'id' => '00000000-0000-4000-8000-000000000703',
            'organization_id' => $organizationId,
            'installation_digest' => hash('sha256', 'release-delivery'),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000704',
            'installation_key_version' => 'v1',
            'pairing_intent_id' => str_repeat('p', 22),
        ]);
        $installation->forceFill(['activation_acknowledged_at' => now('UTC')])->save();

        return $installation->refresh();
    }

    private function release(string $organizationId, string $encodedRelease, \DateTimeInterface $expiresAt, int $version): OperatorSmsPatternRelease
    {
        if (! Organization::query()->whereKey($organizationId)->exists()) {
            (new Organization)->forceFill(['id' => $organizationId])->save();
        }
        $issuer = User::factory()->create(['organization_id' => $organizationId]);
        $proposal = OperatorSmsPatternProposal::query()->create([
            'organization_id' => $organizationId,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'template' => 'Paid {amount} {currency} ref {reference}',
            'template_sha256' => hash('sha256', $encodedRelease),
            'status' => 'approved',
            'reviewed_by_user_id' => $issuer->id,
            'reviewed_at' => now('UTC'),
        ]);

        return OperatorSmsPatternRelease::query()->create([
            'operator_sms_pattern_proposal_id' => $proposal->id,
            'organization_id' => $organizationId,
            'provider' => 'ORANGE_MONEY',
            'sender' => 'ORANGE',
            'pattern_version' => $version,
            'encoded_release' => $encodedRelease,
            'expires_at' => $expiresAt,
            'issued_by_user_id' => $issuer->id,
            'issued_at' => now('UTC'),
        ]);
    }
}
