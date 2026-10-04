<?php

declare(strict_types=1);

namespace App\Filament\Pages;

use App\DeveloperApplications\CustomerWalletAccess;
use App\DeveloperApplications\ManageDeveloperApplicationCredentials;
use App\Models\Customer;
use App\Models\DeveloperApplication;
use App\Models\DeveloperApplicationCredentialAudit;
use App\Models\User;
use App\Models\WalletWebhookDelivery;
use App\Models\WebhookEndpoint;
use App\Security\FinancialOperatorMfaSession;
use App\Webhooks\ManageWebhookEndpoint;
use Filament\Actions\Action;
use Filament\Forms\Components\CheckboxList;
use Filament\Forms\Components\Select;
use Filament\Forms\Components\TextInput;
use Filament\Forms\Components\Toggle;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Collection;
use Illuminate\Validation\ValidationException;

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

    public function customerWalletAccessAction(): Action
    {
        return Action::make('customerWalletAccess')
            ->label('Customer access')
            ->schema([
                Select::make('customer_id')->label('Customer reference')
                    ->options(fn (): array => Customer::query()
                        ->where('organization_id', $this->verifiedActor()->organization_id)
                        ->orderBy('id')->pluck('id', 'id')->all())
                    ->searchable(),
                TextInput::make('customer_lookup_identifier')->label('Or provision a new customer lookup')
                    ->maxLength(255)->helperText('Use the exact customer identifier that the approved SMS template extracts. No payment or balance is created.'),
                Toggle::make('grant')->label('Allow wallet access')->default(true),
            ])
            ->action(function (array $data, array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                $lookup = $data['customer_lookup_identifier'] ?? null;
                if ((! is_string($lookup) || trim($lookup) === '') && empty($data['customer_id'])) {
                    throw ValidationException::withMessages(['customer_id' => 'Select a customer or provide a new lookup identifier.']);
                }
                if (is_string($lookup) && trim($lookup) !== '') {
                    if (! empty($data['customer_id']) || ! ($data['grant'] ?? false)) {
                        throw ValidationException::withMessages(['customer_lookup_identifier' => 'Provisioning requires a new lookup and an access grant.']);
                    }
                    app(CustomerWalletAccess::class)->provision($this->verifiedActor(), $application->id, $lookup);
                    Notification::make()->success()->title('Customer provisioned and access granted.')->send();

                    return;
                }
                app(CustomerWalletAccess::class)->change(
                    $this->verifiedActor(), $application->id,
                    (string) $data['customer_id'], (bool) ($data['grant'] ?? false),
                );
                Notification::make()->success()->title('Customer access updated.')->send();
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

    public function configureWebhookAction(): Action
    {
        return Action::make('configureWebhook')->label('Configure webhook')
            ->schema([
                TextInput::make('url')->label('HTTPS callback URL')->url()->maxLength(2048)->required(),
                TextInput::make('signing_secret')->label('Signing secret')->password()->minLength(32)->maxLength(255)->required(),
                Toggle::make('enabled')->default(true),
            ])
            ->action(function (array $data, array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                app(ManageWebhookEndpoint::class)->configure(
                    $this->verifiedActor(), $application->id, (string) $data['url'],
                    (string) $data['signing_secret'], (bool) ($data['enabled'] ?? false),
                );
                Notification::make()->success()->title('Webhook configured.')->send();
            });
    }

    public function pauseWebhookAction(): Action
    {
        return Action::make('pauseWebhook')->label('Pause webhook')->requiresConfirmation()
            ->action(function (array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                app(ManageWebhookEndpoint::class)->pause($this->verifiedActor(), $application->id);
            });
    }

    public function replayWebhookAction(): Action
    {
        return Action::make('replayWebhook')->label('Retry delivery')->requiresConfirmation()
            ->action(function (array $arguments): void {
                $application = $this->authorizedApplication((string) ($arguments['application'] ?? ''));
                app(ManageWebhookEndpoint::class)->replay(
                    $this->verifiedActor(), $application->id, (string) ($arguments['delivery'] ?? ''),
                );
            });
    }

    /** @return Collection<int, WalletWebhookDelivery> */
    public function webhookDeliveries(): Collection
    {
        $applicationIds = $this->applications()->modelKeys();
        $endpointIds = WebhookEndpoint::query()->whereIn('developer_application_id', $applicationIds)->pluck('id');

        return WalletWebhookDelivery::query()->whereIn('webhook_endpoint_id', $endpointIds)
            ->latest('created_at')->limit(20)->get();
    }

    public function deliveryApplication(string $endpointId): string
    {
        return (string) WebhookEndpoint::query()->whereKey($endpointId)
            ->whereIn('developer_application_id', $this->applications()->modelKeys())->value('developer_application_id');
    }

    /** @return Collection<int, DeveloperApplicationCredentialAudit> */
    public function auditHistory(): Collection
    {
        $actor = $this->verifiedActor();

        return DeveloperApplicationCredentialAudit::query()
            ->with('developerApplication')
            ->where('organization_id', $actor->organization_id)
            ->orderByDesc('created_at')
            ->orderByDesc('organization_sequence')
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
