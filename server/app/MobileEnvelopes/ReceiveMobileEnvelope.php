<?php

declare(strict_types=1);

namespace App\MobileEnvelopes;

use App\Deposits\MobileDepositInput;
use App\Deposits\RecordResult;
use App\Deposits\SubmitMobileDeposit;
use App\Models\SourceInstallation;
use Illuminate\Support\Facades\DB;
use JsonException;

final readonly class ReceiveMobileEnvelope
{
    private const string RequestDomain = 'openpaycongo/mobile/request-envelope/v1';

    private const string ResponseDomain = 'openpaycongo/mobile/response-envelope/v1';

    public function __construct(private SubmitMobileDeposit $deposits) {}

    /** @param array<string, mixed> $outer */
    public function receive(array $outer): MobileEnvelopeResponse
    {
        [$installationId, $counter, $nonce, $ciphertext] = $this->parseOuter($outer);

        return DB::transaction(function () use ($installationId, $counter, $nonce, $ciphertext): MobileEnvelopeResponse {
            $installation = SourceInstallation::query()->lockForUpdate()->find($installationId);
            if ($installation === null || $counter <= $installation->mobile_replay_counter) {
                throw new MobileEnvelopeUnavailable;
            }

            $plaintext = sodium_crypto_aead_xchacha20poly1305_ietf_decrypt(
                $ciphertext,
                $this->requestAad($installationId, $counter),
                $nonce,
                $installation->mobile_receive_key,
            );
            if ($plaintext === false) {
                throw new MobileEnvelopeUnavailable;
            }

            try {
                $inner = json_decode($plaintext, true, 512, JSON_THROW_ON_ERROR);
            } catch (JsonException) {
                throw new MobileEnvelopeUnavailable;
            } finally {
                sodium_memzero($plaintext);
            }

            $payload = $this->depositPayload($inner);
            $result = $this->deposits->submit($installation, MobileDepositInput::validate($payload));
            $installation->forceFill(['mobile_replay_counter' => $counter])->save();

            return $this->encryptResponse($installation, $counter, match ($result->outcome) {
                RecordResult::Recorded => 201,
                RecordResult::Replayed => 200,
                RecordResult::Conflict => 409,
            }, $result->outcome->value);
        }, attempts: 3);
    }

    /** @param array<string, mixed> $outer @return array{string, int, string, string} */
    private function parseOuter(array $outer): array
    {
        $expected = ['version', 'installation_id', 'counter', 'nonce', 'ciphertext'];
        if (count($outer) !== count($expected)
            || array_diff(array_keys($outer), $expected) !== []
            || ($outer['version'] ?? null) !== 1
            || ! is_string($outer['installation_id'] ?? null)
            || ! is_string($outer['counter'] ?? null)
            || ! is_string($outer['nonce'] ?? null)
            || ! is_string($outer['ciphertext'] ?? null)
            || ! $this->isCanonicalUuid($outer['installation_id'])) {
            throw new MobileEnvelopeUnavailable;
        }

        if (strlen($outer['nonce']) !== 32
            || strlen($outer['ciphertext']) < 22
            || strlen($outer['ciphertext']) > 16_384) {
            throw new MobileEnvelopeUnavailable;
        }

        $counter = $this->counter($outer['counter']);
        $nonce = $this->decodeBase64Url(
            $outer['nonce'],
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
            SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES,
        );
        $ciphertext = $this->decodeBase64Url($outer['ciphertext'], SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_ABYTES, 12_288);

        if ($counter === null || $nonce === null || $ciphertext === null) {
            throw new MobileEnvelopeUnavailable;
        }

        return [$outer['installation_id'], $counter, $nonce, $ciphertext];
    }

    /** @param mixed $inner @return array<string, mixed> */
    private function depositPayload(mixed $inner): array
    {
        if (! is_array($inner)
            || array_is_list($inner)
            || count($inner) !== 3
            || array_diff(array_keys($inner), ['version', 'operation', 'payload']) !== []
            || ($inner['version'] ?? null) !== 1
            || ($inner['operation'] ?? null) !== 'deposit'
            || ! is_array($inner['payload'] ?? null)
            || array_is_list($inner['payload'])) {
            throw new MobileEnvelopeUnavailable;
        }

        return $inner['payload'];
    }

    private function encryptResponse(SourceInstallation $installation, int $counter, int $status, string $outcome): MobileEnvelopeResponse
    {
        $nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
        $plaintext = json_encode(['outcome' => $outcome], JSON_THROW_ON_ERROR);

        try {
            $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
                $plaintext,
                $this->responseAad($installation->id, $counter, $status),
                $nonce,
                $installation->mobile_send_key,
            );
        } finally {
            sodium_memzero($plaintext);
        }

        return new MobileEnvelopeResponse($status, $this->encodeBase64Url($nonce), $this->encodeBase64Url($ciphertext));
    }

    private function requestAad(string $installationId, int $counter): string
    {
        return pack('n', strlen(self::RequestDomain)).self::RequestDomain.$this->uuidBytes($installationId).$this->counterBytes($counter);
    }

    private function responseAad(string $installationId, int $counter, int $status): string
    {
        return pack('n', strlen(self::ResponseDomain)).self::ResponseDomain.$this->uuidBytes($installationId).$this->counterBytes($counter).pack('n', $status);
    }

    private function counterBytes(int $counter): string
    {
        return pack('N2', intdiv($counter, 4_294_967_296), $counter % 4_294_967_296);
    }

    private function uuidBytes(string $uuid): string
    {
        $bytes = hex2bin(str_replace('-', '', $uuid));
        if ($bytes === false) {
            throw new MobileEnvelopeUnavailable;
        }

        return $bytes;
    }

    private function counter(string $counter): ?int
    {
        if (preg_match('/^[1-9][0-9]{0,18}$/D', $counter) !== 1 || strlen($counter) > strlen((string) PHP_INT_MAX)) {
            return null;
        }

        if (strlen($counter) === strlen((string) PHP_INT_MAX) && strcmp($counter, (string) PHP_INT_MAX) > 0) {
            return null;
        }

        return (int) $counter;
    }

    private function isCanonicalUuid(string $uuid): bool
    {
        return preg_match('/^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/D', $uuid) === 1;
    }

    private function decodeBase64Url(string $value, int $minimumLength, ?int $maximumLength = null): ?string
    {
        if ($value === '' || preg_match('/^[A-Za-z0-9_-]+$/D', $value) !== 1) {
            return null;
        }

        $decoded = base64_decode(strtr($value.str_repeat('=', (4 - strlen($value) % 4) % 4), '-_', '+/'), true);
        if ($decoded === false
            || strlen($decoded) < $minimumLength
            || ($maximumLength !== null && strlen($decoded) > $maximumLength)
            || ! hash_equals($value, $this->encodeBase64Url($decoded))) {
            return null;
        }

        return $decoded;
    }

    private function encodeBase64Url(string $value): string
    {
        return rtrim(strtr(base64_encode($value), '+/', '-_'), '=');
    }
}
