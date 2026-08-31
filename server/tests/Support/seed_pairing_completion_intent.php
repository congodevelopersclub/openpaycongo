<?php

use App\Models\Organization;
use App\Models\PairingIntent;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$intentBytes = hex2bin('00112233445566778899aabbccddeeff');
if ($intentBytes === false) {
    throw new RuntimeException('Pairing concurrency fixture unavailable.');
}

$organization = new Organization;
$organization->id = '00000000-0000-4000-8000-000000000017';
$organization->save();
PairingIntent::query()->create([
    'organization_id' => $organization->id,
    'intent_id' => 'ABEiM0RVZneImaq7zN3u_w',
    'intent_id_bytes' => $intentBytes,
    'state' => 'pending',
    'expires_at' => now()->addMinutes(5),
    'protected_server_private_material' => 'test-only-protected-material',
]);
