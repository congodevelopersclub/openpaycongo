<?php

use Illuminate\Foundation\Inspiring;
use Illuminate\Support\Facades\Artisan;
use Illuminate\Support\Facades\Schedule;

Artisan::command('inspire', function () {
    $this->comment(Inspiring::quote());
})->purpose('Display an inspiring quote');

Schedule::command('payment-requests:recover-credit')->everyMinute()->withoutOverlapping();
Schedule::command('payment-requests:recover-allocation-deliveries')->everyMinute()->withoutOverlapping();
Schedule::command('pairing:expire-intents')->everyMinute()->withoutOverlapping();
