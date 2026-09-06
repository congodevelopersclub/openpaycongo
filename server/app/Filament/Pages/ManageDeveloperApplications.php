<?php

declare(strict_types=1);

namespace App\Filament\Pages;

use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Models\DeveloperApplication;
use App\Models\DeveloperApplicationCredentialAudit;
use App\Models\User;
use App\Security\FinancialOperatorMfaSession;
use Filament\Actions\Action;
use Filament\Forms\Components\CheckboxList;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Collection;

final class ManageDeveloperApplications extends Page
{
    protected string $view = 'filament.pages.manage-developer-applications';

    protected static ?string $navigationLabel = 'Developer credentials';

    public function mount(): void
    {
        $this->verifiedActor();
    }

    public function issueDeveloperApplicationAction(): Action
    {
        return Action::make('issueDeveloperApplication')
            ->label('Issue credentials')
            ->schema([
                TextInput::make('name')
                    ->label('Application name')
                    ->maxLength(120)
                    ->required(),
                CheckboxList::make('scopes')
                    ->label('Allowed scopes')
                    ->options(fn (): array => app(ManageDeveloperApplicationCredentials::class)->availableScopes())
                    ->default(['payment-requests:read'])
                    ->required()
                    ->columns(1),
            ])
            ->action(function (array $data): void {
                $issued = app(ManageDeveloperApplicationCredentials::class)->issue(
                    $this->verifiedActor(),
                    (string) $data['name'],
                    is_array($data['scopes'] ?? null) ? $data['scopes'] : [],
                );

                $this->dispatch('developer-application-credentials-issued',
                    clientId: $issued->clientId,
                    clientSecret: $issued->clientSecret,
                );

                Notification::make()
                    ->success()
                    ->title('Developer application credentials issued.')
                    ->send();
            });
    }

    public function rotateDeveloperApplicationAction(): Action
    {
        return Action::make('rotateDeveloperApplication')
            ->label('Rotate')
            ->requiresConfirmation()
            ->action(function (array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                $issued = app(ManageDeveloperApplicationCredentials::class)->rotate($this->verifiedActor(), $application);

                $this->dispatch('developer-application-credentials-issued',
                    clientId: $issued->clientId,
                    clientSecret: $issued->clientSecret,
                );

                Notification::make()
                    ->success()
                    ->title('Developer application credentials rotated.')
                    ->send();
            });
    }

    public function revokeDeveloperApplicationAction(): Action
    {
        return Action::make('revokeDeveloperApplication')
            ->label('Revoke')
            ->color('danger')
            ->requiresConfirmation()
            ->action(function (array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                app(ManageDeveloperApplicationCredentials::class)->revoke($this->verifiedActor(), $application);
                $this->dispatch('developer-application-credentials-cleared');

                Notification::make()
                    ->success()
                    ->title('Developer application credentials revoked.')
                    ->send();
            });
    }

    /** @return Collection<int, DeveloperApplication> */
    public function applications(): Collection
    {
        $actor = $this->verifiedActor();

        return DeveloperApplication::query()
            ->with('oauthClient')
            ->where('organization_id', $actor->organization_id)
            ->latest('created_at')
            ->get();
    }

    /** @return Collection<int, DeveloperApplicationCredentialAudit> */
    public function auditHistory(): Collection
    {
        $actor = $this->verifiedActor();

        return DeveloperApplicationCredentialAudit::query()
            ->where('organization_id', $actor->organization_id)
            ->latest('created_at')
            ->limit(10)
            ->get();
    }

    private function authorizedApplication(string $applicationId): DeveloperApplication
    {
        return DeveloperApplication::query()
            ->whereKey($applicationId)
            ->where('organization_id', $this->verifiedActor()->organization_id)
            ->firstOrFail();
    }

    private function verifiedActor(): User
    {
        $actor = auth()->user();
        abort_unless($actor instanceof User && $actor->is_financial_operator && is_string($actor->organization_id), 404);

        app(FinancialOperatorMfaSession::class)->assertVerified($actor);

        return $actor;
    }
}
