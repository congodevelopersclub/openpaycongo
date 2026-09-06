<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsInterpretationRequest;

final readonly class OperatorSmsInterpretationRequestResult
{
    public function __construct(
        public OperatorSmsInterpretationRequest $request,
        public bool $recorded,
    ) {}
}
