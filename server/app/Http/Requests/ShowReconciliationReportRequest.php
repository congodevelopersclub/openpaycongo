<?php

namespace App\Http\Requests;

use App\Models\Deposit;
use Illuminate\Foundation\Http\FormRequest;

final class ShowReconciliationReportRequest extends FormRequest
{
    public function authorize(): bool
    {
        $deposit = $this->route('deposit');

        return $deposit instanceof Deposit && $this->user()?->can('view', $deposit) === true;
    }

    public function rules(): array
    {
        return [];
    }
}
