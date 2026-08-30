<?php

$production = env('APP_ENV') === 'production';
$relyingPartyId = env('OPENPAY_PASSKEY_RP_ID', $production ? null : 'localhost');
$allowedOrigins = json_decode((string) env('OPENPAY_PASSKEY_ALLOWED_ORIGINS', $production ? '[]' : '["https://localhost"]'), true);
$userHandleSecret = env('OPENPAY_PASSKEY_USER_HANDLE_SECRET', $production ? null : env('APP_KEY'));
$canonicalOrigin = env('OPENPAY_APP_URL', $production ? null : 'https://localhost');
$passportKeysPath = env('OPENPAY_PASSPORT_KEYS_PATH', $production ? null : storage_path());

$passkeysConfigured = is_string($relyingPartyId)
    && $relyingPartyId !== ''
    && is_array($allowedOrigins)
    && $allowedOrigins === [$canonicalOrigin]
    && is_string($canonicalOrigin)
    && parse_url($canonicalOrigin, PHP_URL_SCHEME) === 'https'
    && parse_url($canonicalOrigin, PHP_URL_HOST) === $relyingPartyId
    && is_string($userHandleSecret)
    && strlen($userHandleSecret) >= 32;

return [
    'passport_keys_path' => $passportKeysPath,
    'passkeys_configured' => $passkeysConfigured,
    'passkeys' => [
        'relying_party_id' => $relyingPartyId,
        'allowed_origins' => $passkeysConfigured ? $allowedOrigins : [],
        'user_handle_secret' => $userHandleSecret,
        'timeout' => 60000,
        'guard' => 'web',
        'middleware' => ['web'],
        'management_middleware' => ['password.confirm'],
        'throttle' => 'throttle:passkeys',
        'redirect' => '/two-factor-challenge',
    ],
];
