<?php

namespace App\Events;

use Illuminate\Contracts\Events\ShouldDispatchAfterCommit;

final readonly class PaymentRequestAllocated implements ShouldDispatchAfterCommit
{
    public function __construct(public string $paymentRequestId) {}
}
