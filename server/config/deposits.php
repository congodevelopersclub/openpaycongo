<?php

return [
    /* Mandatory dedicated token material; never fall back to APP_KEY. */
    'lookup_token_key' => env('DEPOSIT_LOOKUP_TOKEN_KEY'),
    'supported_currencies' => ['CDF'],
];
