<?php

declare(strict_types=1);

namespace App\OperatorSms;

/**
 * A machine-authored candidate. It deliberately cannot be approved or signed
 * here: those transitions require the developer review workflow.
 */
final readonly class OperatorPaymentPatternCandidate
{
    public function __construct(
        public string $provider,
        public string $sender,
        public string $template,
    ) {
    }

    public function isApproved(): bool
    {
        return false;
    }
}
