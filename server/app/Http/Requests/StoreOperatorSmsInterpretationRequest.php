<?php

declare(strict_types=1);

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Validator;

/**
 * This endpoint is an explicit user action from the protected review screen.
 * It is never called while merely reading the SMS inbox.
 */
final class StoreOperatorSmsInterpretationRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** @return array<string, array<int, string>> */
    public function rules(): array
    {
        return [
            'record_id' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{8,64}$/'],
            'sender' => ['required', 'string', 'regex:/^(?:\\+[1-9][0-9]{7,14}|[A-Z0-9]{3,11})$/'],
            'sms_body' => ['required', 'string', 'min:1', 'max:4096'],
            'received_at' => ['required', 'date_format:Y-m-d\\TH:i:s\\Z'],
        ];
    }

    /** @return array<int, callable(Validator): void> */
    public function after(): array
    {
        return [function (Validator $validator): void {
            $receivedAt = $this->input('received_at');
            if (! is_string($receivedAt)) {
                return;
            }

            try {
                $parsed = new \DateTimeImmutable($receivedAt);
                if ($parsed->format('Y-m-d\\TH:i:s\\Z') !== $receivedAt) {
                    $validator->errors()->add('received_at', 'The received timestamp is invalid.');
                }
            } catch (\Throwable) {
                $validator->errors()->add('received_at', 'The received timestamp is invalid.');
            }
        }];
    }
}
