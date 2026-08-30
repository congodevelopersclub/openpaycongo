<?php

namespace App\Events;

use Illuminate\Contracts\Events\ShouldDispatchAfterCommit;

final readonly class ProviderDepositRecorded implements ShouldDispatchAfterCommit
{
    public function __construct(public string $depositId) {}
}
