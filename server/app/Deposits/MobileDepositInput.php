<?php

declare(strict_types=1);

namespace App\Deposits;

use DateTimeImmutable;
use DateTimeZone;
use Illuminate\Support\Facades\Validator;
use Illuminate\Validation\ValidationException;

final class MobileDepositInput
{
    /** @return array<string, array<int, string>> */
    public static function rules(): array
    {
        return [
            'organization_id' => ['prohibited'],
            'source_installation_id' => ['prohibited'],
            'customer_lookup_identifier' => ['required', 'string', 'min:1', 'max:255', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'provider_reference' => ['required', 'string', 'min:1', 'max:255', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'amount_minor' => ['required', 'integer', 'min:1'],
            'currency' => ['required', 'string', 'in:CDF'],
            'provider_occurred_at' => ['required', 'string', 'max:25', 'regex:/^\\d{4}-\\d{2}-\\d{2}T\\d{2}:\\d{2}:\\d{2}(?:Z|[+-]\\d{2}:\\d{2})$/'],
            'sender_identifier' => ['nullable', 'string', 'min:1', 'max:255', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'receiver_identifier' => ['nullable', 'string', 'min:1', 'max:255', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'customer_name' => ['nullable', 'string', 'min:1', 'max:255', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'customer_address' => ['nullable', 'string', 'min:1', 'max:2000', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'customer_phone' => ['nullable', 'string', 'min:1', 'max:64', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
            'customer_email' => ['nullable', 'string', 'min:1', 'max:320', 'not_regex:/[\\x00-\\x1F\\x7F]/'],
        ];
    }

    /** @param array<string, mixed> $input @return array<string, mixed> */
    public static function validate(array $input): array
    {
        if (array_diff(array_keys($input), array_keys(self::rules())) !== []) {
            throw ValidationException::withMessages(['payload' => 'The deposit payload is invalid.']);
        }

        $validator = Validator::make($input, self::rules());
        $validator->after(static function (\Illuminate\Validation\Validator $validator) use ($input): void {
            $providerOccurredAt = $input['provider_occurred_at'] ?? null;
            if (is_string($providerOccurredAt) && ! self::isStrictPortableTimestamp($providerOccurredAt)) {
                $validator->errors()->add('provider_occurred_at', 'The provider occurrence timestamp is invalid.');
            }
        });

        return $validator->validate();
    }

    public static function isStrictPortableTimestamp(string $value): bool
    {
        if (preg_match('/^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:Z|[+-](?<hours>\d{2}):(?<minutes>\d{2}))$/D', $value, $offset) !== 1
            || (isset($offset['hours']) && ((int) $offset['hours'] > 23 || (int) $offset['minutes'] > 59))) {
            return false;
        }

        $timestamp = DateTimeImmutable::createFromFormat(DATE_ATOM, $value);
        $errors = DateTimeImmutable::getLastErrors();
        if ($timestamp === false || ($errors !== false && ($errors['warning_count'] !== 0 || $errors['error_count'] !== 0))) {
            return false;
        }

        $canonical = $timestamp->format(DATE_ATOM);
        if ($canonical !== $value && ! ($timestamp->getOffset() === 0 && $value === substr($canonical, 0, -6).'Z')) {
            return false;
        }

        $year = (int) $timestamp->setTimezone(new DateTimeZone('UTC'))->format('Y');

        return $year >= 1000 && $year <= 9999;
    }
}
