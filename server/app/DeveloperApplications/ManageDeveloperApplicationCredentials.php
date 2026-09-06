<?php

declare(strict_types=1);

namespace App\DeveloperApplications;

use App\Models\DeveloperApplication;
use App\Models\DeveloperApplicationCredentialAudit;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Auth\Access\AuthorizationException;
use Illuminate\Database\Eloquent\Builder;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use Laravel\Passport\Client;
use Laravel\Passport\ClientRepository;
use Laravel\Passport\Passport;

final class ManageDeveloperApplicationCredentials
{
    /** @param string[] $scopes */
    public function issue(User $actor, string $name, array $scopes): IssuedDeveloperApplicationCredentials
    {
        $organizationId = $this->authorizedOrganizationId($actor);
        $scopes = $this->validatedScopes($scopes);
        $name = $this->validatedName($name);

        return DB::transaction(function () use ($actor, $organizationId, $name, $scopes): IssuedDeveloperApplicationCredentials {
            $client = $this->issueClient($name, $scopes);
            $application = DeveloperApplication::query()->create([
                'organization_id' => $organizationId,
                'name' => $name,
                'oauth_client_id' => $client->getKey(),
            ]);

            $this->recordAudit($actor, $application, $client, 'issued', $scopes);

            return new IssuedDeveloperApplicationCredentials(
                application: $application,
                clientId: (string) $client->getKey(),
                clientSecret: (string) $client->plainSecret,
            );
        });
    }

    public function rotate(User $actor, DeveloperApplication $application): IssuedDeveloperApplicationCredentials
    {
        $this->assertCanManage($actor, $application);

        return DB::transaction(function () use ($actor, $application): IssuedDeveloperApplicationCredentials {
            $application = DeveloperApplication::query()->lockForUpdate()->findOrFail($application->getKey());
            $this->assertCanManage($actor, $application);

            $oldClient = $application->oauthClient()->firstOrFail();
            $scopes = $this->clientScopes($oldClient);
            $newClient = $this->issueClient($application->name ?? $oldClient->name, $scopes);

            $oldClient->forceFill(['revoked' => true])->save();
            $application->forceFill(['oauth_client_id' => $newClient->getKey()])->save();

            $this->recordAudit($actor, $application, $newClient, 'rotated', $scopes);

            return new IssuedDeveloperApplicationCredentials(
                application: $application->refresh(),
                clientId: (string) $newClient->getKey(),
                clientSecret: (string) $newClient->plainSecret,
            );
        });
    }

    public function revoke(User $actor, DeveloperApplication $application): void
    {
        $this->assertCanManage($actor, $application);

        DB::transaction(function () use ($actor, $application): void {
            $application = DeveloperApplication::query()->lockForUpdate()->findOrFail($application->getKey());
            $this->assertCanManage($actor, $application);
            $client = $application->oauthClient()->firstOrFail();
            $scopes = $this->clientScopes($client);

            $client->forceFill(['revoked' => true])->save();
            $this->recordAudit($actor, $application, $client, 'revoked', $scopes);
        });
    }

    /** @return array<string, string> */
    public function availableScopes(): array
    {
        return collect(Passport::scopes())
            ->reject(static fn ($scope): bool => (string) $scope->id === 'customers:pii:read')
            ->mapWithKeys(static fn ($scope): array => [(string) $scope->id => (string) $scope->description])
            ->all();
    }

    private function authorizedOrganizationId(User $actor): string
    {
        if (! $actor->is_financial_operator || ! is_string($actor->organization_id)) {
            throw new AuthorizationException;
        }

        return $actor->organization_id;
    }

    private function assertCanManage(User $actor, DeveloperApplication $application): void
    {
        if ($application->organization_id !== $this->authorizedOrganizationId($actor)) {
            throw new AuthorizationException;
        }
    }

    private function validatedName(string $name): string
    {
        $name = trim($name);

        if ($name === '') {
            throw new AuthorizationException;
        }

        return Str::limit($name, 120, '');
    }

    /**
     * @param string[] $scopes
     * @return string[]
     */
    private function validatedScopes(array $scopes): array
    {
        $allowed = array_keys($this->availableScopes());
        $selected = array_values(array_unique(array_map('strval', $scopes)));

        if ($selected === [] || array_diff($selected, $allowed) !== []) {
            throw new AuthorizationException;
        }

        return $selected;
    }

    /** @param string[] $scopes */
    private function issueClient(string $name, array $scopes): Client
    {
        $client = app(ClientRepository::class)->createClientCredentialsGrantClient($name);
        $client->forceFill(['scopes' => $scopes])->save();

        return $client;
    }

    /** @return string[] */
    private function clientScopes(Client $client): array
    {
        $scopes = $client->scopes;

        return is_array($scopes) ? array_values(array_map('strval', $scopes)) : [];
    }

    /** @param string[] $scopes */
    private function recordAudit(User $actor, DeveloperApplication $application, Client $client, string $action, array $scopes): void
    {
        DeveloperApplicationCredentialAudit::query()->create([
            'organization_id' => $application->organization_id,
            'developer_application_id' => $application->getKey(),
            'oauth_client_id' => $client->getKey(),
            'actor_user_id' => $actor->getKey(),
            'actor_user_identifier' => (string) $actor->getKey(),
            'action' => $action,
            'scopes' => $scopes,
            'organization_sequence' => $this->nextAuditSequence($application->organization_id),
        ]);
    }

    private function nextAuditSequence(string $organizationId): int
    {
        Organization::query()
            ->whereKey($organizationId)
            ->lockForUpdate()
            ->firstOrFail();

        return (int) $this->auditSequenceQuery($organizationId)
            ->value('organization_sequence') + 1;
    }

    /** @return Builder<DeveloperApplicationCredentialAudit> */
    private function auditSequenceQuery(string $organizationId): Builder
    {
        return DeveloperApplicationCredentialAudit::query()
            ->where('organization_id', $organizationId)
            ->orderByDesc('organization_sequence')
            ->lockForUpdate();
    }
}
