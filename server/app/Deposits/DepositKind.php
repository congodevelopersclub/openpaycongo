<?php

namespace App\Deposits;

enum DepositKind: string
{
    case ProviderCredit = 'provider_credit';
    case ProviderReversal = 'provider_reversal';

}
