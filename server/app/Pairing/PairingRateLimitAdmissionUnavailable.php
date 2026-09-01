<?php

declare(strict_types=1);

namespace App\Pairing;

use RuntimeException;

final class PairingRateLimitAdmissionUnavailable extends RuntimeException {}
