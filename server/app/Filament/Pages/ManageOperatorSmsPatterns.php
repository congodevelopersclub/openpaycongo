<?php

declare(strict_types=1);

namespace App\Filament\Pages;

use App\Models\OperatorSmsPatternProposal;
use App\Models\User;
use App\OperatorSms\OperatorPaymentPatternReview;
use App\OperatorSms\ReleaseApprovedOperatorPaymentPattern;
use App\Security\FinancialOperatorMfaSession;
use Carbon\CarbonImmutable;
use Filament\Actions\Action;
use Filament\Forms\Components\DateTimePicker;
use Filament\Forms\Components\Select;
use Filament\Notifications\Notification;
use Filament\Pages\Page;
use Illuminate\Database\Eloquent\Collection;

/** Developer-gated review surface; no raw SMS evidence is rendered here. */
final class ManageOperatorSmsPatterns extends Page
{
    protected string $view = 'filament.pages.manage-operator-sms-patterns';

    protected static ?string $navigationLabel = 'SMS payment patterns';

    public function mount(): void
    {
        $this->verifiedActor();
    }

    public function approvePatternAction(): Action
    {
        return Action::make('approvePattern')
            ->label('Approve proposal')
            ->requiresConfirmation()
            ->schema([
                Select::make('proposal_id')->label('Review-only proposal')->options(fn (): array => $this->proposalOptions('pending_review'))->required(),
            ])
            ->action(function (array $data): void {
                app(OperatorPaymentPatternReview::class)->approve(
                    $this->verifiedActor(),
                    $this->authorizedProposal((string) $data['proposal_id'], 'pending_review'),
                );
                Notification::make()->success()->title('Proposal approved. It is not active until a signed release is created.')->send();
            });
    }

    public function releasePatternAction(): Action
    {
        return Action::make('releasePattern')
            ->label('Create signed mobile release')
            ->color('warning')
            ->requiresConfirmation()
            ->schema([
                Select::make('proposal_id')->label('Approved proposal')->options(fn (): array => $this->proposalOptions('approved'))->required(),
                DateTimePicker::make('expires_at')->label('Expiry (UTC)')->seconds(false)->native(false)->required()->minDate(now('UTC')->addMinute()),
            ])
            ->action(function (array $data): void {
                app(ReleaseApprovedOperatorPaymentPattern::class)->release(
                    $this->verifiedActor(),
                    $this->authorizedProposal((string) $data['proposal_id'], 'approved'),
                    CarbonImmutable::parse((string) $data['expires_at'], 'UTC'),
                );
                Notification::make()->success()->title('Signed release created for paired mobile clients.')->send();
            });
    }

    /** @return Collection<int, OperatorSmsPatternProposal> */
    public function proposals(): Collection
    {
        return OperatorSmsPatternProposal::query()
            ->where('organization_id', $this->verifiedActor()->organization_id)
            ->latest('created_at')
            ->limit(100)
            ->get();
    }

    /** @return array<string, string> */
    private function proposalOptions(string $status): array
    {
        return OperatorSmsPatternProposal::query()
            ->where('organization_id', $this->verifiedActor()->organization_id)
            ->where('status', $status)
            ->orderByDesc('created_at')
            ->get()
            ->mapWithKeys(static fn (OperatorSmsPatternProposal $proposal): array => [
                $proposal->id => $proposal->provider.' / '.$proposal->sender.' / '.$proposal->template,
            ])->all();
    }

    private function authorizedProposal(string $id, string $status): OperatorSmsPatternProposal
    {
        return OperatorSmsPatternProposal::query()
            ->whereKey($id)
            ->where('organization_id', $this->verifiedActor()->organization_id)
            ->where('status', $status)
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
