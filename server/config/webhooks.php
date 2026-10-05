<?php

return [
    'allowed_hosts' => json_decode((string) env('OPENPAY_WEBHOOK_ALLOWED_HOSTS', '[]'), true),
    'timeout_seconds' => 5,
];
