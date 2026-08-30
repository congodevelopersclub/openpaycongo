<?php

return [
    // A request either charges in full or remains pending; it never takes partial credit.
    'partial_credit_policy' => 'all_or_nothing',
    'pending_expiry_days' => (int) env('PAYMENT_REQUEST_PENDING_EXPIRY_DAYS', 90),
];
