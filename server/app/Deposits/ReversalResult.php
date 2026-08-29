<?php

namespace App\Deposits;

enum ReversalResult: string
{
    case Reversed = 'reversed';
    case Replayed = 'replayed';
}
