<?php

namespace App\Http\Controllers;

use App\DeveloperApplications\CustomerWalletAccess;
use App\Models\CustomerCredit;
use App\Models\DeveloperApplication;
use Illuminate\Http\JsonResponse;
use Illuminate\Http\Request;

final class ShowCustomerWalletController
{
    public function __invoke(Request $request, string $customer, CustomerWalletAccess $access): JsonResponse
    {
        /** @var DeveloperApplication $application */
        $application = $request->attributes->get(DeveloperApplication::class);
        $authorized = $access->customer($application, $customer);
        $balances = CustomerCredit::query()->where('customer_id', $authorized->id)
            ->orderBy('currency')->get(['currency', 'available_minor']);

        return response()->json([
            'customer_id' => $authorized->id,
            'settlement_status' => 'unverified',
            'balances' => $balances->map(static fn (CustomerCredit $credit): array => [
                'currency' => $credit->currency,
                'available_minor' => (int) $credit->available_minor,
            ])->all(),
        ], 200, ['cache-control' => 'no-store, private']);
    }
}
