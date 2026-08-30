<?php

use Laravel\Fortify\Features;

$production = env('APP_ENV') === 'production';
$relyingPartyId = env('OPENPAY_PASSKEY_RP_ID', $production ? null : 'localhost');
$allowedOrigins = json_decode(
    (string) env('OPENPAY_PASSKEY_ALLOWED_ORIGINS', $production ? '[]' : '["https://localhost"]'),
    true,
);
$userHandleSecret = env('OPENPAY_PASSKEY_USER_HANDLE_SECRET', $production ? null : env('APP_KEY'));
$canonicalOrigin = env('OPENPAY_APP_URL', $production ? null : 'https://localhost');

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
    'guard' => 'web',
    'middleware' => ['web'],
    'auth_middleware' => 'auth',
    'passwords' => 'users',
    'username' => 'email',
    'email' => 'email',
    'views' => true,
    'home' => '/operations',
    'limiters' => [
        'login' => 'login',
        'two-factor' => 'two-factor',
        'passkeys' => 'passkeys',
    ],
    'passkeys' => [
        'relying_party_id' => $relyingPartyId,
        'allowed_origins' => $allowedOrigins,
        'user_handle_secret' => $userHandleSecret,
        'timeout' => 60000,
    ],
    'features' => [
        Features::twoFactorAuthentication(['confirm' => true, 'confirmPassword' => true]),
        ...($passkeysConfigured ? [Features::passkeys(['confirmPassword' => true])] : []),
    ],
];
