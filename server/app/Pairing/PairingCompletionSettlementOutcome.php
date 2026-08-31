<?php

declare(strict_types=1);

namespace App\Pairing;

/** Durable settlement state; it never contains proof, key, or cached result data. */
enum PairingCompletionSettlementOutcome: string
{
    case Settled = 'settled';
    case Stale = 'stale';
    case Unknown = 'unknown';
}
