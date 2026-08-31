<?php

namespace Tests\Feature;

use App\Models\Organization;
use App\Models\PairingIntent;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Session\TokenMismatchException;
use Illuminate\Support\Facades\Route;
use Illuminate\Testing\TestResponse;
use Tests\TestCase;

final class IssuePairingIntentHttpTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        config(['openpay.pairing' => [
            'endpoint' => 'https://pairing.openpay.example/v1/pairing/complete',
            'enrollment_signing_secret' => rtrim(strtr(base64_encode(str_repeat('s', 32)), '+/', '-_'), '='),
            'trust_mode' => 'first_use_requires_sas',
        ]]);
    }

    public function test_authenticated_administrator_issues_only_public_qr_for_own_organization(): void
    {
        $organization = Organization::query()->create();
        $administrator = User::factory()->create();
        $administrator->forceFill([
            'organization_id' => $organization->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ])->save();

        $response = $this->actingAs($administrator)->withSession([
            'financial_operator_mfa.user_id' => $administrator->getAuthIdentifier(),
        ])->postJson('/v1/pairing/intents', [
            'lifetime_seconds' => 60,
        ]);

        $response->assertCreated()
            ->assertJsonStructure([
                'version', 'endpoint', 'intent_id', 'intent_nonce', 'expires_at', 'algorithms',
                'enrollment_signing_fingerprint', 'enrollment_signing_public_key',
                'server_key_agreement_public_key', 'trust_mode', 'signature',
            ])
            ->assertJsonMissing(['protected_server_private_material']);
        $this->assertPairingNoStore($response);
        self::assertCount(11, $response->json());
        self::assertSame($organization->getKey(), PairingIntent::query()->sole()->organization_id);
        self::assertNotSame(
            PairingIntent::query()->sole()->protected_server_private_material,
            $response->getContent(),
        );
    }

    public function test_an_unauthenticated_request_is_rejected_before_an_intent_is_issued(): void
    {
        $response = $this->postJson('/v1/pairing/intents', ['lifetime_seconds' => 60]);

        $this->assertPairingProblem($response, 401);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_a_non_financial_user_is_rejected_before_an_intent_is_issued(): void
    {
        $user = User::factory()->create([
            'organization_id' => Organization::query()->create()->getKey(),
            'is_financial_operator' => false,
        ]);

        $response = $this->actingAs($user)->postJson('/v1/pairing/intents', ['lifetime_seconds' => 60]);

        $this->assertPairingProblem($response, 403);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_a_financial_operator_without_an_established_mfa_session_is_rejected(): void
    {
        $operator = $this->financialOperator();

        $response = $this->actingAs($operator)->postJson('/v1/pairing/intents', ['lifetime_seconds' => 60]);

        $this->assertPairingProblem($response, 403);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_only_a_short_integer_lifetime_is_accepted(): void
    {
        $user = $this->financialOperator();

        foreach ([29, 301, '60', 60.5] as $lifetime) {
            $response = $this->verifiedPost($user, ['lifetime_seconds' => $lifetime]);

            $this->assertPairingProblem($response, 422);
        }

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_the_request_cannot_select_an_organization(): void
    {
        $user = $this->financialOperator();

        $response = $this->verifiedPost($user, [
            'lifetime_seconds' => 60,
            'organization_id' => Organization::query()->create()->getKey(),
        ]);

        $this->assertPairingProblem($response, 422);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_csrf_failures_use_the_public_pairing_problem_contract(): void
    {
        Route::post('/testing/pairing-intents-csrf', static function (): never {
            throw new TokenMismatchException;
        })->name('pairing.intents.csrf');

        $response = $this->postJson('/testing/pairing-intents-csrf');

        $this->assertPairingProblem($response, 419);

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_unhandled_pairing_errors_do_not_expose_the_exception_or_configuration(): void
    {
        config(['openpay.pairing.enrollment_signing_secret' => 'invalid-secret']);
        $operator = $this->financialOperator();

        $response = $this->verifiedPost($operator, ['lifetime_seconds' => 60]);

        $this->assertPairingProblem($response, 500);
        $response->assertDontSee('Invalid pairing configuration.')
            ->assertDontSee('invalid-secret');

        self::assertDatabaseCount('pairing_intents', 0);
    }

    public function test_throttle_isolated_by_verified_operator_and_organization(): void
    {
        $organization = Organization::query()->create();
        $firstOperator = $this->financialOperator($organization);
        $secondOperator = $this->financialOperator($organization);
        $otherOrganizationOperator = $this->financialOperator();

        for ($attempt = 0; $attempt < 5; $attempt++) {
            $this->verifiedPost($firstOperator, ['lifetime_seconds' => 60])->assertCreated();
        }

        $this->assertPairingProblem(
            $this->verifiedPost($firstOperator, ['lifetime_seconds' => 60]),
            429,
            'pairing_rate_limited',
        );
        $this->verifiedPost($secondOperator, ['lifetime_seconds' => 60])->assertCreated();
        $this->verifiedPost($otherOrganizationOperator, ['lifetime_seconds' => 60])->assertCreated();
    }

    /** @param array<string, mixed> $payload */
    private function verifiedPost(User $operator, array $payload): TestResponse
    {
        return $this->actingAs($operator)->withSession([
            'financial_operator_mfa.user_id' => $operator->getAuthIdentifier(),
        ])->postJson('/v1/pairing/intents', $payload);
    }

    private function assertPairingProblem(TestResponse $response, int $status, string $code = 'pairing_request_failed'): void
    {
        $response->assertStatus($status)
            ->assertHeader('Content-Type', 'application/problem+json')
            ->assertJsonPath('type', $code === 'pairing_rate_limited'
                ? 'https://openpaycongo.example/problems/pairing-rate-limited'
                : 'https://openpaycongo.example/problems/pairing-request-failed')
            ->assertJsonPath('title', $code === 'pairing_rate_limited'
                ? 'Pairing request rate limited'
                : 'Pairing request failed')
            ->assertJsonPath('status', $status)
            ->assertJsonPath('code', $code)
            ->assertJsonStructure(['type', 'title', 'status', 'code', 'request_id']);

        self::assertSame(['type', 'title', 'status', 'code', 'request_id'], array_keys($response->json()));
        self::assertMatchesRegularExpression('/^[0-9a-f-]{36}$/', (string) $response->json('request_id'));
        $this->assertPairingNoStore($response);

        if ($status === 429) {
            self::assertMatchesRegularExpression('/^[1-9][0-9]*$/', (string) $response->headers->get('Retry-After'));
        }
    }

    private function assertPairingNoStore(TestResponse $response): void
    {
        self::assertSame(
            ['no-store', 'private'],
            array_values(array_intersect(
                ['no-store', 'private'],
                array_map('trim', explode(',', (string) $response->headers->get('Cache-Control'))),
            )),
        );
    }

    private function financialOperator(?Organization $organization = null): User
    {
        return User::factory()->create([
            'organization_id' => ($organization ?? Organization::query()->create())->getKey(),
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
    }
}
