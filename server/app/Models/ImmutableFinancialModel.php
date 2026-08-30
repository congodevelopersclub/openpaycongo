<?php

namespace App\Models;

use Illuminate\Database\Eloquent\Model;
use LogicException;

abstract class ImmutableFinancialModel extends Model
{
    public function save(array $options = []): bool
    {
        if ($this->exists) {
            throw new LogicException('Financial records are immutable.');
        }

        return parent::save($options);
    }

    public function delete(): ?bool
    {
        if ($this->exists) {
            throw new LogicException('Financial records are immutable.');
        }

        return parent::delete();
    }

    /**
     * This is the non-suppressible Eloquent boundary for increment(), decrement(),
     * and their quiet variants. Raw query-builder and direct SQL writes are
     * outside this model guard and must be restricted by deployment database
     * privileges or triggers.
     */
    protected function incrementOrDecrement($column, $amount, $extra, $method): int
    {
        throw new LogicException('Financial records are immutable.');
    }

    public function forceDelete()
    {
        throw new LogicException('Financial records are immutable.');
    }
}
