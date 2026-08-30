<?php

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$result = $app->make(RecordProviderDeposit::class)->record(new ProviderTransfer(
    organizationId: '00000000-0000-4000-8000-000000000165',
    installationIdentifier: 'concurrency-installation',
    customerLookupIdentifier: 'concurrency-customer',
    providerReference: 'concurrency-provider-reference',
    amountMinor: (int) (getenv('DEPOSIT_TEST_AMOUNT_MINOR') ?: 12500),
    currency: 'CDF',
    providerOccurredAt: '2026-08-30T01:00:00Z',
    senderIdentifier: null,
    receiverIdentifier: null,
));

fwrite(STDOUT, $result->outcome->value.PHP_EOL);
