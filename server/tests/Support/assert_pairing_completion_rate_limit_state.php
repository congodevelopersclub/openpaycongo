<?php

use Illuminate\Contracts\Console\Kernel;
use Illuminate\Support\Facades\RateLimiter;

require dirname(__DIR__, 2).'/vendor/autoload.php';

$app = require dirname(__DIR__, 2).'/bootstrap/app.php';
$app->make(Kernel::class)->bootstrap();

$attempts = RateLimiter::attempts('pairing-completion-concurrency');
if ($attempts < 1 || $attempts > 10) {
    throw new RuntimeException('Pairing completion rate-limit admission is not bounded.');
}
