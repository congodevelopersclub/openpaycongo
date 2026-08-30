<?php

return [
    'guard' => [],
    'expiration' => env('OPENPAY_MOBILE_TOKEN_EXPIRATION', 1440),
    'token_prefix' => env('SANCTUM_TOKEN_PREFIX', ''),
];
