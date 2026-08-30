<?php

namespace App\OAuth;

use Laravel\Passport\Bridge\ScopeRepository as PassportScopeRepository;
use League\OAuth2\Server\Entities\ClientEntityInterface;
use League\OAuth2\Server\Entities\ScopeEntityInterface;
use League\OAuth2\Server\Exception\OAuthServerException;

final class ClientScopeRepository extends PassportScopeRepository
{
    /**
     * @param  ScopeEntityInterface[]  $scopes
     * @return ScopeEntityInterface[]
     */
    public function finalizeScopes(
        array $scopes,
        string $grantType,
        ClientEntityInterface $clientEntity,
        ?string $userIdentifier = null,
        ?string $authCodeId = null,
    ): array {
        $finalizedScopes = parent::finalizeScopes($scopes, $grantType, $clientEntity, $userIdentifier, $authCodeId);
        $grantedScopeIds = array_map(static fn (ScopeEntityInterface $scope): string => $scope->getIdentifier(), $finalizedScopes);

        foreach ($scopes as $scope) {
            if (! in_array($scope->getIdentifier(), $grantedScopeIds, true)) {
                throw OAuthServerException::invalidScope($scope->getIdentifier());
            }
        }

        return $finalizedScopes;
    }
}
