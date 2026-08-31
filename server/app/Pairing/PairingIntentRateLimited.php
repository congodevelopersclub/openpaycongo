<?php

declare(strict_types=1);

namespace App\Pairing;

use Symfony\Component\HttpKernel\Exception\TooManyRequestsHttpException;

final class PairingIntentRateLimited extends TooManyRequestsHttpException
{
    public function __construct(int $retryAfter)
    {
        parent::__construct(max(1, $retryAfter));
    }
}
