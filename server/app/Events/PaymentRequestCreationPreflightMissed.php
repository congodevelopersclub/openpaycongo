<?php

namespace App\Events;

final readonly class PaymentRequestCreationPreflightMissed
{
    public function __construct(public string $customerId) {}
}
