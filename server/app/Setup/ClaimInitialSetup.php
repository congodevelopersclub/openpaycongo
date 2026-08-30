<?php

namespace App\Setup;

use App\Models\InitialSetupState;
use App\Models\Organization;
use App\Models\User;
use Illuminate\Support\Facades\DB;
use Illuminate\Support\Facades\Hash;
use Symfony\Component\HttpKernel\Exception\NotFoundHttpException;

final class ClaimInitialSetup
{
    /**
     * @param array{username: string, name: string, email: string, password: string} $attributes
     */
    public function claim(array $attributes): User
    {
        return DB::transaction(function () use ($attributes): User {
            $state = InitialSetupState::query()->lockForUpdate()->findOrFail(1);

            if ($state->completed_at !== null) {
                throw new NotFoundHttpException();
            }

            $organization = Organization::query()->create();
            $user = new User([
                'username' => $attributes['username'],
                'name' => $attributes['name'],
                'email' => $attributes['email'],
                'password' => Hash::make($attributes['password']),
            ]);
            $user->organization_id = $organization->getKey();
            $user->is_financial_operator = true;
            $user->save();

            $state->forceFill(['completed_at' => now()])->save();

            return $user;
        });
    }
}
