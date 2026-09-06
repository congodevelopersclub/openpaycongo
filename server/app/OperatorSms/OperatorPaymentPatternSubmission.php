<?php

declare(strict_types=1);

namespace App\OperatorSms;

use InvalidArgumentException;

/**
 * A user-authorized payment SMS submitted for server-side pattern analysis.
 * This value is intentionally ephemeral; persistence belongs to the review
 * workflow, not to the model adapter.
 */
final readonly class OperatorPaymentPatternSubmission
{
    public function __construct(
        public string $sender,
        public string $body,
        public string $provider,
    ) {
        if (!preg_match('/^[A-Z0-9._-]{3,32}$/', $provider)
            || trim($sender) === '' || mb_strlen($sender) > 64
            || trim($body) === '' || mb_strlen($body) > 4096) {
            throw new InvalidArgumentException('operator_payment_pattern_submission_invalid');
        }
    }
}
