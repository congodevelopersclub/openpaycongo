<?php

namespace App\Http\Requests;

use App\Deposits\MobileDepositInput;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Validation\Validator;

final class StoreMobileDepositRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /** @return array<string, array<int, string>> */
    public function rules(): array
    {
        return MobileDepositInput::rules();
    }

    /** @return array<int, callable(Validator): void> */
    public function after(): array
    {
        return [function (Validator $validator): void {
            $providerOccurredAt = $this->input('provider_occurred_at');
            if (is_string($providerOccurredAt) && ! MobileDepositInput::isStrictPortableTimestamp($providerOccurredAt)) {
                $validator->errors()->add('provider_occurred_at', 'The provider occurrence timestamp is invalid.');
            }
        }];
    }
}
