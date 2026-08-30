<?php

namespace App\Deposits;

enum RecordResult: string
{
    case Recorded = 'recorded';
    case Replayed = 'replayed';
    case Conflict = 'conflict';
}
