<?php

use App\Models\Customer;
use App\Models\CustomerCredit;
use Illuminate\Contracts\Console\Kernel;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$customer = Customer::query()->forceCreate([
    'id' => '00000000-0000-4000-8000-000000000166',
    'organization_id' => '00000000-0000-4000-8000-000000000001',
    'private_lookup_digest' => str_repeat('a', 64),
    'private_lookup_id' => '00000000-0000-4000-8000-000000000167',
    'private_lookup_key_version' => 'v1',
]);

CustomerCredit::query()->create([
    'customer_id' => $customer->id,
    'currency' => 'CDF',
    'available_minor' => 100,
]);

echo $customer->id;
