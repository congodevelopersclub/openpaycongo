<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Concerns\HasUuids;
use Illuminate\Database\Eloquent\Model;
use Illuminate\Database\Eloquent\Relations\BelongsTo;

final class WebhookEndpoint extends Model
{
    use HasUuids;

    public $incrementing = false;

    protected $keyType = 'string';

    protected $fillable = ['developer_application_id', 'url', 'signing_secret', 'enabled', 'configured_by_user_id'];

    protected $hidden = ['signing_secret', 'url'];

    protected function casts(): array
    {
        return ['signing_secret' => 'encrypted', 'enabled' => 'boolean'];
    }

    /** @return BelongsTo<DeveloperApplication, $this> */
    public function developerApplication(): BelongsTo
    {
        return $this->belongsTo(DeveloperApplication::class);
    }
}
