<?php

namespace App\Http\Controllers;

use App\Deposits\ProviderTransfer;
use App\Deposits\RecordProviderDeposit;
use App\Deposits\RecordResult;
use App\Http\Requests\StoreMobileDepositRequest;
use App\Models\SourceInstallation;
use Illuminate\Http\JsonResponse;

final class StoreMobileDepositController
{
    public function __invoke(StoreMobileDepositRequest $request, RecordProviderDeposit $record): JsonResponse
    {
        /** @var SourceInstallation $installation */
        $installation = $request->user('mobile');
        $result = $record->record(new ProviderTransfer(
            organizationId: $installation->organization_id,
            installationIdentifier: $installation->id,
            customerLookupIdentifier: (string) $request->input('customer_lookup_identifier'),
            providerReference: (string) $request->input('provider_reference'),
            amountMinor: (int) $request->input('amount_minor'),
            currency: (string) $request->input('currency'),
            providerOccurredAt: (string) $request->input('provider_occurred_at'),
            senderIdentifier: $request->input('sender_identifier'),
            receiverIdentifier: $request->input('receiver_identifier'),
            customerName: $request->input('customer_name'),
            customerAddress: $request->input('customer_address'),
            customerPhone: $request->input('customer_phone'),
            customerEmail: $request->input('customer_email'),
        ), $installation);

        return response()->json(['outcome' => $result->outcome->value], match ($result->outcome) {
            RecordResult::Recorded => 201,
            RecordResult::Replayed => 200,
            RecordResult::Conflict => 409,
        }, ['cache-control' => 'no-store']);
    }
}
