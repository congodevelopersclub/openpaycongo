<?php

use App\MobileEnvelopes\MobileEnvelopeUnavailable;
use App\MobileEnvelopes\ReceiveMobileEnvelope;
use App\Models\SourceInstallation;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrierDirectory = getenv('MOBILE_ENVELOPE_TEST_BARRIER_DIRECTORY');
if (is_string($barrierDirectory) && $barrierDirectory !== '') {
    $worker = (string) (getenv('MOBILE_ENVELOPE_TEST_WORKER') ?: 'worker');
    touch($barrierDirectory.'/'.$worker.'.ready');
    $deadline = microtime(true) + 60;

    while (file_exists($barrierDirectory.'/release') === false) {
        if (microtime(true) >= $deadline) {
            throw new RuntimeException('Timed out waiting for the mobile envelope test barrier.');
        }

        usleep(10_000);
    }
}

$installation = SourceInstallation::query()->findOrFail('00000000-0000-4000-8000-000000000210');
$counter = (string) (getenv('MOBILE_ENVELOPE_TEST_COUNTER') ?: '1');
$worker = (string) (getenv('MOBILE_ENVELOPE_TEST_WORKER') ?: 'retry');
$nonce = random_bytes(SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_NPUBBYTES);
$ciphertext = '';
$plaintext = json_encode([
    'version' => 1,
    'operation' => 'deposit',
    'payload' => [
        'customer_lookup_identifier' => 'mobile-envelope-concurrency-customer',
        'provider_reference' => 'mobile-envelope-concurrency-'.$worker,
        'amount_minor' => 12500,
        'currency' => 'CDF',
        'provider_occurred_at' => '2026-09-01T01:00:00Z',
    ],
], JSON_THROW_ON_ERROR);

try {
    $ciphertext = sodium_crypto_aead_xchacha20poly1305_ietf_encrypt(
        $plaintext,
        pack('n', 39).'openpaycongo/mobile/request-envelope/v1'.hex2bin(str_replace('-', '', $installation->id)).pack('N2', 0, (int) $counter),
        $nonce,
        $installation->mobile_receive_key,
    );
} finally {
    sodium_memzero($plaintext);
}

try {
    $result = $app->make(ReceiveMobileEnvelope::class)->receive([
        'version' => 1,
        'installation_id' => $installation->id,
        'counter' => $counter,
        'nonce' => rtrim(strtr(base64_encode($nonce), '+/', '-_'), '='),
        'ciphertext' => rtrim(strtr(base64_encode($ciphertext), '+/', '-_'), '='),
    ]);

    fwrite(STDOUT, $result->status === 201 ? "created\n" : "unexpected\n");
} catch (MobileEnvelopeUnavailable) {
    fwrite(STDOUT, "unavailable\n");
} finally {
    sodium_memzero($nonce);
    sodium_memzero($ciphertext);
}
