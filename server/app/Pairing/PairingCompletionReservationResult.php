<?php

declare(strict_types=1);

namespace App\Pairing;

enum PairingCompletionReservationOutcome: string
{
    case Reserved = 'reserved';
    case Replayed = 'replayed';
    case Unavailable = 'unavailable';
}

/** Opaque state handoff. It intentionally contains neither proof nor key material. */
final readonly class PairingCompletionReservationResult
{
    private function __construct(
        private PairingCompletionReservationOutcome $outcome,
        private ?string $reservationId = null,
        private ?string $cachedResult = null,
    ) {}

    public static function reserved(string $reservationId): self
    {
        return new self(PairingCompletionReservationOutcome::Reserved, $reservationId);
    }

    public static function replayed(string $cachedResult): self
    {
        return new self(PairingCompletionReservationOutcome::Replayed, cachedResult: $cachedResult);
    }

    public static function unavailable(): self
    {
        return new self(PairingCompletionReservationOutcome::Unavailable);
    }

    public function outcome(): PairingCompletionReservationOutcome
    {
        return $this->outcome;
    }

    public function reservationId(): ?string
    {
        return $this->reservationId;
    }

    public function cachedResult(): ?string
    {
        return $this->cachedResult;
    }
}
