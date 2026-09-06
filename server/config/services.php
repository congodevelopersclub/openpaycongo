<?php

return [

    /*
    |--------------------------------------------------------------------------
    | Third Party Services
    |--------------------------------------------------------------------------
    |
    | This file is for storing the credentials for third party services such
    | as Resend, Postmark, AWS, and more. This file provides the de facto
    | location for this type of information, allowing packages to have
    | a conventional file to locate the various service credentials.
    |
    */

    'postmark' => [
        'key' => env('POSTMARK_API_KEY'),
    ],

    'resend' => [
        'key' => env('RESEND_API_KEY'),
    ],

    'gemma' => [
        // Raw SMS evidence may only reach a private, backend-controlled Gemma
        // runtime. Do not configure a public hosted-model URL here.
        'private_inference_url' => env('GEMMA_PRIVATE_INFERENCE_URL'),
        'auth_token' => env('GEMMA_PRIVATE_INFERENCE_TOKEN'),
        'model' => env('GEMMA_MODEL', 'gemma-4-26b-a4b-it'),
        'timeout_seconds' => (int) env('GEMMA_TIMEOUT_SECONDS', 20),
    ],

    'ses' => [
        'key' => env('AWS_ACCESS_KEY_ID'),
        'secret' => env('AWS_SECRET_ACCESS_KEY'),
        'region' => env('AWS_DEFAULT_REGION', 'us-east-1'),
    ],

    'slack' => [
        'notifications' => [
            'bot_user_oauth_token' => env('SLACK_BOT_USER_OAUTH_TOKEN'),
            'channel' => env('SLACK_BOT_USER_DEFAULT_CHANNEL'),
        ],
    ],

];
