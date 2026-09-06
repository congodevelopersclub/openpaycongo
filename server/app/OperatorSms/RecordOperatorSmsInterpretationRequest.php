<?php

declare(strict_types=1);

namespace App\OperatorSms;

use App\Models\OperatorSmsInterpretationRequest;
use App\Models\SourceInstallation;
use Carbon\CarbonImmutable;

final class RecordOperatorSmsInterpretationRequest
{
    /**
     * The authenticated installation, not a client-supplied field, supplies
     * tenant authority. The encrypted body is intentionally not returned.
     *
     * @param array{record_id: string, sender: string, sms_body: string, received_at: string} $input
     */
    public function record(SourceInstallation $installation, array $input): OperatorSmsInterpretationRequestResult
    {
        $days = config('openpay.operator_sms_patterns.interpretation_retention_days');
        $retentionDays = is_int($days) && $days >= 1 && $days <= 90 ? $days : 30;
        $request = OperatorSmsInterpretationRequest::query()->firstOrCreate(
            [
                'source_installation_id' => $installation->id,
                'sms_record_id' => $input['record_id'],
            ],
            [
                'organization_id' => $installation->organization_id,
                'sender' => $input['sender'],
                'protected_sms_body' => $input['sms_body'],
                'received_at' => CarbonImmutable::parse($input['received_at'], 'UTC'),
                'expires_at' => now('UTC')->addDays($retentionDays),
            ],
        );

        return new OperatorSmsInterpretationRequestResult(
            request: $request,
            recorded: $request->wasRecentlyCreated,
        );
    }
}
