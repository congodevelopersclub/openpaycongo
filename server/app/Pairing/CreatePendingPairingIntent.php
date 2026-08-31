<?php

declare(strict_types=1);

namespace App\Pairing;

use App\Models\PairingIntent;
use DateTimeInterface;
use Illuminate\Database\QueryException;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Str;
use InvalidArgumentException;

final readonly class CreatePendingPairingIntent
{
    public function __construct(private KeyProtector $protector) {}

    public function execute(string $organizationId, string $intentId, DateTimeInterface $expiresAt, string $serverPrivateMaterial): PairingIntent
    {
        $this->assertInput($organizationId, $intentId, $expiresAt, $serverPrivateMaterial);

        $protectedMaterial = $this->protector->protect(
            $serverPrivateMaterial,
            $this->aad($organizationId, $intentId),
        );

        if ($protectedMaterial === '' || strlen($protectedMaterial) > 1024) {
            throw new PairingIntentUnavailable;
        }

        try {
            return DB::transaction(static fn (): PairingIntent => PairingIntent::query()->create([
                'organization_id' => $organizationId,
                'intent_id' => $intentId,
                'state' => 'pending',
                'expires_at' => $expiresAt,
                'protected_server_private_material' => $protectedMaterial,
            ]));
        } catch (QueryException $exception) {
            throw new PairingIntentUnavailable(previous: $exception);
        }
    }

    private function assertInput(string $organizationId, string $intentId, DateTimeInterface $expiresAt, string $serverPrivateMaterial): void
    {
        $decodedIntent = preg_match('/^[A-Za-z0-9_-]{22}$/D', $intentId) === 1
            ? base64_decode(strtr($intentId, '-_', '+/'), true)
            : false;
        $secondsUntilExpiry = now()->diffInSeconds($expiresAt, false);

        if (Str::isUuid($organizationId) === false
            || $decodedIntent === false
            || strlen($decodedIntent) !== 16
            || rtrim(strtr(base64_encode($decodedIntent), '+/', '-_'), '=') !== $intentId
            || strlen($serverPrivateMaterial) !== 32
            || $secondsUntilExpiry < 30
            || $secondsUntilExpiry > 300) {
            throw new InvalidArgumentException('Invalid pairing intent input.');
        }
    }

    private function aad(string $organizationId, string $intentId): string
    {
        return 'openpaycongo/pairing/intent-server-private-material/v1/'.$organizationId.'/'.$intentId;
    }
}
