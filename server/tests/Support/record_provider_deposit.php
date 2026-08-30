<?php

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use Illuminate\Contracts\Console\Kernel;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrierDirectory = getenv('DEPOSIT_TEST_BARRIER_DIRECTORY');
if (is_string($barrierDirectory) && $barrierDirectory !== '') {
    $worker = getenv('DEPOSIT_TEST_WORKER') ?: 'worker';
    touch($barrierDirectory.'/'.$worker.'.ready');

    while (! file_exists($barrierDirectory.'/release')) {
        usleep(10_000);
    }
}

$result = $app->make(RecordProviderDeposit::class)->record(new ProviderTransfer(
    organizationId: '00000000-0000-4000-8000-000000000165',
    installationIdentifier: getenv('DEPOSIT_TEST_INSTALLATION_IDENTIFIER') ?: 'concurrency-installation',
    customerLookupIdentifier: getenv('DEPOSIT_TEST_CUSTOMER_IDENTIFIER') ?: 'concurrency-customer',
    providerReference: getenv('DEPOSIT_TEST_PROVIDER_REFERENCE') ?: 'concurrency-provider-reference',
    amountMinor: (int) (getenv('DEPOSIT_TEST_AMOUNT_MINOR') ?: 12500),
    currency: 'CDF',
    providerOccurredAt: '2026-08-30T01:00:00Z',
    senderIdentifier: getenv('DEPOSIT_TEST_SENDER_IDENTIFIER') ?: null,
    receiverIdentifier: getenv('DEPOSIT_TEST_RECEIVER_IDENTIFIER') ?: null,
));

fwrite(STDOUT, $result->outcome->value.PHP_EOL);
