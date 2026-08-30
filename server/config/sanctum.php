<?php

return [
    // Mobile installation credentials are bearer tokens only; never fall back to web sessions.
    'guard' => [],

    'expiration' => env('OPENPAY_MOBILE_TOKEN_EXPIRATION', 1440),

    'token_prefix' => env('SANCTUM_TOKEN_PREFIX', ''),

    'routes' => false,
];
