<?php

use App\Events\CustomerCreditCreationPending;
use App\Models\Deposit;
use App\Models\User;
use App\Reconciliation\ReverseDeposit;
use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\Event;

require __DIR__.'/../../vendor/autoload.php';

$app = require __DIR__.'/../../bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$barrier = (string) getenv('PAYMENT_REQUEST_TEST_BARRIER_DIRECTORY');
$worker = (string) getenv('PAYMENT_REQUEST_TEST_WORKER');
touch($barrier.'/'.$worker.'.ready');
$deadline = microtime(true) + 30;
while (! file_exists($barrier.'/release')) {
    if (microtime(true) > $deadline) {
        throw new RuntimeException('Timed out waiting for payment request reversal barrier.');
    }

    usleep(10_000);
}

Event::listen(CustomerCreditCreationPending::class, function () use ($barrier, $worker): void {
    touch($barrier.'/'.$worker.'.transaction-ready');
    $deadline = microtime(true) + 30;
    while (! file_exists($barrier.'/transaction-release')) {
        if (microtime(true) > $deadline) {
            throw new RuntimeException('Timed out waiting for payment request reversal transaction barrier.');
        }
        usleep(10_000);
    }
});

$actor = User::query()->create(['name' => 'Test operator', 'email' => 'test-operator-'.$worker.'@example.test', 'password' => 'unused']);
$actor->is_financial_operator = true;
$actor->save();
$result = app(ReverseDeposit::class)->reverse($actor, Deposit::query()->findOrFail((string) getenv('PAYMENT_REQUEST_TEST_DEPOSIT_ID')), 'provider_correction');
echo $result->outcome->value.PHP_EOL;
