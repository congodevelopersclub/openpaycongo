<?php

return [
    // A request either charges in full or remains pending; it never takes partial credit.
    'partial_credit_policy' => 'all_or_nothing',
    'pending_expiry_days' => (int) env('PAYMENT_REQUEST_PENDING_EXPIRY_DAYS', 90),

    /*
     * Payment-request idempotency keys use purpose-separated HMACs. By default
     * they share the mandatory deposit lookup key ring so rotation remains one
     * coordinated operational change without introducing an APP_KEY fallback.
     * Rotation is two-phase: deploy the complete old+new ring everywhere while
     * the old key stays active, then flip the active id everywhere. Payment
     * requests are retained, so every key version referenced by a retained row
     * must remain in the ring. Creation fails closed if a persisted version is
     * removed; retirement requires an explicit row-retention/purge migration.
     */
    'idempotency_key' => env('PAYMENT_REQUEST_IDEMPOTENCY_KEY', env('DEPOSIT_LOOKUP_TOKEN_KEY')),
    'idempotency_keys' => env('PAYMENT_REQUEST_IDEMPOTENCY_KEYS', env('DEPOSIT_LOOKUP_TOKEN_KEYS')),
    'idempotency_active_key_id' => env('PAYMENT_REQUEST_IDEMPOTENCY_ACTIVE_KEY_ID', env('DEPOSIT_LOOKUP_TOKEN_ACTIVE_KEY_ID')),
];
