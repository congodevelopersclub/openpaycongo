<?php

namespace App\Events;

final readonly class CustomerCreditCreationPending
{
    public function __construct(public string $customerId, public string $currency) {}
}
