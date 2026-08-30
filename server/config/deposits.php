<?php

return [
    /*
     * Mandatory dedicated token material; never fall back to APP_KEY.
     *
     * lookup_token_key is the single-key compatibility form. Deployments that
     * rotate must configure lookup_token_keys as a JSON object and choose one
     * of its names as lookup_token_active_key_id.
     */
    'lookup_token_key' => env('DEPOSIT_LOOKUP_TOKEN_KEY'),
    'lookup_token_keys' => env('DEPOSIT_LOOKUP_TOKEN_KEYS'),
    'lookup_token_active_key_id' => env('DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID'),
    'supported_currencies' => ['CDF'],
];
