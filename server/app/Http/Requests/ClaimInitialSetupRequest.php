<?php

namespace App\Http\Requests;

use Illuminate\Foundation\Http\FormRequest;

final class ClaimInitialSetupRequest extends FormRequest
{
    public function authorize(): bool
    {
        return true;
    }

    /**
     * @return array<string, array<int, string>>
     */
    public function rules(): array
    {
        return [
            'username' => ['required', 'string', 'min:3', 'max:80', 'alpha_dash', 'unique:users,username'],
            'name' => ['required', 'string', 'min:1', 'max:120'],
            'email' => ['required', 'string', 'email:rfc', 'max:255', 'unique:users,email'],
            'password' => ['required', 'string', 'min:15', 'confirmed'],
        ];
    }
}
