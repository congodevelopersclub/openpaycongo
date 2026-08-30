<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;

final class Organization extends Model
{
    use HasUuids;

    protected $keyType = 'string';

    public $incrementing = false;
}
