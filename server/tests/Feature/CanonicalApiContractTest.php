<?php

declare(strict_types=1);

namespace Tests\Feature;

use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Models\DeveloperApplication;
use App\Models\Organization;
use App\Models\SourceInstallation;
use App\Models\User;
use Illuminate\Foundation\Testing\RefreshDatabase;
use Illuminate\Support\Facades\Artisan;
use Laravel\Sanctum\Sanctum;
use Symfony\Component\Yaml\Yaml;
use Tests\TestCase;

final class CanonicalApiContractTest extends TestCase
{
    use RefreshDatabase;

    protected function setUp(): void
    {
        parent::setUp();

        Artisan::call('passport:keys', ['--force' => true]);
    }

    public function test_mobile_deposit_responses_conform_to_the_published_openapi_schema(): void
    {
        $installation = SourceInstallation::query()->create([
            'organization_id' => '00000000-0000-4000-8000-000000000001',
            'installation_digest' => str_repeat('a', 64),
            'installation_lookup_id' => '00000000-0000-4000-8000-000000000002',
            'installation_key_version' => 'v1',
        ]);
        Sanctum::actingAs($installation, ['mobile:deposits:write'], 'mobile');
        $payload = [
            'customer_lookup_identifier' => 'customer-fixture-001',
            'provider_reference' => 'provider-fixture-001',
            'amount_minor' => 12500,
            'currency' => 'CDF',
            'provider_occurred_at' => '2026-08-01T12:34:56Z',
        ];

        $recorded = $this->postJson('/mobile/deposits', $payload)->assertCreated();
        $this->assertConforms('/mobile/deposits', 'post', 201, $recorded->json());

        $replayed = $this->postJson('/mobile/deposits', $payload)->assertOk();
        $this->assertConforms('/mobile/deposits', 'post', 200, $replayed->json());

        $conflict = $this->postJson('/mobile/deposits', [...$payload, 'amount_minor' => 12600])->assertConflict();
        $this->assertConforms('/mobile/deposits', 'post', 409, $conflict->json());
    }

    public function test_developer_identity_response_conforms_to_the_published_openapi_schema(): void
    {
        $organizationId = '00000000-0000-4000-8000-000000000201';
        Organization::query()->forceCreate(['id' => $organizationId]);
        $operator = User::factory()->create([
            'organization_id' => $organizationId,
            'is_financial_operator' => true,
            'two_factor_confirmed_at' => now(),
            'recovery_codes_confirmed_at' => now(),
        ]);
        $issued = app(ManageDeveloperApplicationCredentials::class)->issue(
            $operator,
            'Contract fixture application',
            ['payment-requests:read'],
        );
        $application = DeveloperApplication::query()->sole();
        $client = $application->oauthClient()->firstOrFail();
        $token = $this->postJson('/oauth/token', [
            'grant_type' => 'client_credentials',
            'client_id' => $client->getKey(),
            'client_secret' => $issued->clientSecret,
            'scope' => 'payment-requests:read',
        ])->assertOk()->json('access_token');

        $response = $this->withToken((string) $token)->getJson('/services/identity')->assertOk();
        $this->assertConforms('/services/identity', 'get', 200, $response->json());
        $response->assertDontSee($issued->clientSecret);
    }

    /** @param array<string, mixed> $value */
    private function assertConforms(string $path, string $method, int $status, array $value): void
    {
        $openapi = Yaml::parseFile(base_path('../docs/openapi.yaml'));
        $schema = $openapi['paths'][$path][$method]['responses'][(string) $status]['content']['application/json']['schema'];
        $this->assertSchema($value, $schema, $openapi, 'response');
    }

    /** @param array<string, mixed> $schema @param array<string, mixed> $openapi */
    private function assertSchema(mixed $value, array $schema, array $openapi, string $location): void
    {
        if (isset($schema['$ref'])) {
            $schema = $this->resolveReference($schema['$ref'], $openapi);
        }

        if (isset($schema['const'])) {
            self::assertSame($schema['const'], $value, $location.' const');
        }
        if (isset($schema['enum'])) {
            self::assertContains($value, $schema['enum'], $location.' enum');
        }

        $types = is_array($schema['type'] ?? null) ? $schema['type'] : [$schema['type'] ?? null];
        $typeMatches = false;
        foreach ($types as $type) {
            $typeMatches = $typeMatches || match ($type) {
                'object' => is_array($value),
                'array' => is_array($value) && array_is_list($value),
                'integer' => is_int($value),
                'string' => is_string($value),
                'null' => $value === null,
                default => true,
            };
        }
        self::assertTrue($typeMatches, $location.' type');

        if (is_array($value) && ! array_is_list($value)) {
            foreach ($schema['required'] ?? [] as $required) {
                self::assertArrayHasKey($required, $value, $location.' required field');
            }
            if (($schema['additionalProperties'] ?? true) === false) {
                self::assertSame([], array_diff(array_keys($value), array_keys($schema['properties'] ?? [])), $location.' additional fields');
            }
            foreach ($schema['properties'] ?? [] as $property => $propertySchema) {
                if (array_key_exists($property, $value)) {
                    $this->assertSchema($value[$property], $propertySchema, $openapi, $location.'.'.$property);
                }
            }
        }

        if (is_string($value)) {
            self::assertGreaterThanOrEqual($schema['minLength'] ?? 0, strlen($value), $location.' minLength');
            if (isset($schema['maxLength'])) {
                self::assertLessThanOrEqual($schema['maxLength'], strlen($value), $location.' maxLength');
            }
        }
    }

    /** @param array<string, mixed> $openapi @return array<string, mixed> */
    private function resolveReference(string $reference, array $openapi): array
    {
        self::assertStringStartsWith('#/', $reference);
        $resolved = $openapi;
        foreach (array_slice(explode('/', $reference), 1) as $segment) {
            $resolved = $resolved[str_replace('~1', '/', str_replace('~0', '~', $segment))];
        }

        self::assertIsArray($resolved);

        return $resolved;
    }
}
