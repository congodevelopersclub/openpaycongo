<?php

namespace App\PaymentRequests;

enum PaymentRequestStatus: string
{
    case Pending = 'pending';
    case Charged = 'charged';
    case Expired = 'expired';
}
