<?php

declare(strict_types=1);

namespace App\Http\Requests;

use App\Models\User;
use Illuminate\Foundation\Http\FormRequest;
use Illuminate\Support\Str;
use Illuminate\Validation\Rule;
use Illuminate\Validation\Validator;

final class ConfirmPairingIntentRequest extends FormRequest
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

    /** @return array<string, array<int, mixed>> */
    public function rules(): array
    {
        return [
            'request_id' => ['required', 'string', 'regex:/^[A-Za-z0-9_-]{22}$/D'],
            'decision' => ['required', 'string', Rule::in(['codes_match', 'codes_mismatch'])],
            'reason' => ['required', 'string', Rule::in(['codes_compared_match', 'codes_compared_mismatch'])],
        ];
    }

    /** @return array<int, callable(Validator): void> */
    public function after(): array
    {
        return [function (Validator $validator): void {
            $input = $this->all();
            if (array_diff(array_keys($input), ['request_id', 'decision', 'reason']) !== []) {
                $validator->errors()->add('request', 'The request contains unexpected fields.');
            }

            $requestId = $this->input('request_id');
            if (is_string($requestId) && ! $this->isCanonicalRequestId($requestId)) {
                $validator->errors()->add('request_id', 'The request id must be canonical base64url.');
            }

            $decision = $this->input('decision');
            $reason = $this->input('reason');
            if (
                ($decision === 'codes_match' && $reason !== 'codes_compared_match')
                || ($decision === 'codes_mismatch' && $reason !== 'codes_compared_mismatch')
            ) {
                $validator->errors()->add('reason', 'The reason must match the confirmation decision.');
            }
        }];
    }

    public function decision(): string
    {
        return $this->string('decision')->toString();
    }

    public function requestId(): string
    {
        return $this->string('request_id')->toString();
    }

    public function operator(): User
    {
        /** @var User $user */
        $user = $this->user();

        return $user;
    }

    private function isCanonicalRequestId(string $value): bool
    {
        $decoded = base64_decode(strtr($value, '-_', '+/').'==', true);

        return is_string($decoded)
            && strlen($decoded) === 16
            && rtrim(strtr(base64_encode($decoded), '+/', '-_'), '=') === $value;
    }
}
