<?php

use App\Models\SourceInstallation;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$installation = new SourceInstallation;
$installation->forceFill([
    'id' => '00000000-0000-4000-8000-000000000210',
    'organization_id' => '00000000-0000-4000-8000-000000000211',
    'installation_digest' => hash('sha256', 'mobile-envelope-concurrency-installation'),
    'installation_lookup_id' => '00000000-0000-4000-8000-000000000212',
    'installation_key_version' => 'test-v1',
    'mobile_receive_key' => str_repeat('r', SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
    'mobile_send_key' => str_repeat('s', SODIUM_CRYPTO_AEAD_XCHACHA20POLY1305_IETF_KEYBYTES),
    'mobile_replay_counter' => 0,
]);
$installation->save();
