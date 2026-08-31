<?php

declare(strict_types=1);

namespace App\Filament\Pages;

use App\Models\User;
use App\Pairing\IssuePendingPairingIntent as IssuePendingPairingIntentAction;
use App\Security\FinancialOperatorMfaSession;
use BaconQrCode\Renderer\Image\SvgImageBackEnd;
use BaconQrCode\Renderer\ImageRenderer;
use BaconQrCode\Renderer\RendererStyle\RendererStyle;
use BaconQrCode\Writer;
use Filament\Actions\Action;
use Filament\Forms\Components\TextInput;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Auth\Access\AuthorizationException;
use JsonException;
use Throwable;

final class IssuePairingIntent extends Page
{
    protected string $view = 'filament.pages.issue-pairing-intent';

    protected static ?string $navigationLabel = 'Pair mobile device';

    public ?string $qrSvg = null;

    public function mount(): void
    {
        $this->verifiedActor();
    }

    public function issuePairingIntentAction(): Action
    {
        return Action::make('issuePairingIntent')
            ->label('Create pairing QR')
            ->schema([
                TextInput::make('lifetime_seconds')
                    ->label('QR lifetime (seconds)')
                    ->integer()
                    ->minValue(30)
                    ->maxValue(300)
                    ->default(60)
                    ->required()
                    ->helperText('Choose between 30 and 300 seconds.'),
            ])
            ->action(function (array $data): void {
                $actor = $this->verifiedActor();

                try {
                    $issued = app(IssuePendingPairingIntentAction::class)->execute(
                        organizationId: $actor->organization_id,
                        lifetimeSeconds: (int) $data['lifetime_seconds'],
                    );
                    $this->qrSvg = $this->renderPublicQr($issued->qr);
                } catch (AuthorizationException $exception) {
                    throw $exception;
                } catch (Throwable) {
                    $this->qrSvg = null;
                    Notification::make()
                        ->danger()
                        ->title('Pairing intent could not be issued.')
                        ->send();
                }
            });
    }

    /** @param array<string, string> $qr */
    private function renderPublicQr(array $qr): string
    {
        try {
            $payload = json_encode($qr, JSON_THROW_ON_ERROR | JSON_UNESCAPED_SLASHES);
        } catch (JsonException) {
            throw new \RuntimeException('Unable to encode public pairing QR.');
        }

        return (new Writer(new ImageRenderer(
            new RendererStyle(320),
            new SvgImageBackEnd,
        )))->writeString($payload);
    }

    private function verifiedActor(): User
    {
        $actor = auth()->user();
        abort_unless($actor instanceof User && $actor->is_financial_operator && is_string($actor->organization_id), 404);

        app(FinancialOperatorMfaSession::class)->assertVerified($actor);

        return $actor;
    }
}
