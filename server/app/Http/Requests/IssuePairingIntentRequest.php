<?php

declare(strict_types=1);

namespace App\Http\Requests;

use App\Models\User;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Str;
use Illuminate\Validation\Validator;

final class IssuePairingIntentRequest extends FormRequest
{
    public function authorize(): bool
    {
        $user = $this->user();

        return $user instanceof User
            && $user->is_financial_operator
            && is_string($user->organization_id)
            && Str::isUuid($user->organization_id)
            && strtolower($user->organization_id) === $user->organization_id;
    }

    /** @return array<string, array<int, string>> */
    public function rules(): array
    {
        return [
            'organization_id' => ['prohibited'],
            'lifetime_seconds' => ['required', 'integer', 'between:30,300'],
        ];
    }

    public function organizationId(): string
    {
        /** @var User $user */
        $user = $this->user();

        return $user->organization_id;
    }

    /** @return array<int, callable(Validator): void> */
    public function after(): array
    {
        return [function (Validator $validator): void {
            if (! is_int($this->input('lifetime_seconds'))) {
                $validator->errors()->add('lifetime_seconds', 'The lifetime seconds field must be an integer.');
            }
        }];
    }
}
