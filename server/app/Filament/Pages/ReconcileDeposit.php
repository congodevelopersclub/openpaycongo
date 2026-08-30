<?php

namespace App\Filament\Pages;

use App\Models\Deposit;
use App\Models\User;
use App\Reconciliation\ReconcileDeposit as ReconcileDepositAction;
use App\Reconciliation\RepairMissingCustomerCredit;
use App\Reconciliation\ReverseDeposit;
use App\Security\FinancialOperatorMfaSession;
use Filament\Actions\Action;
use Filament\Forms\Components\Select;
use Filament\Pages\Page;
use Illuminate\Support\Collection;
use Illuminate\Support\Facades\Gate;

final class ReconcileDeposit extends Page
{
    protected string $view = 'filament.pages.reconcile-deposit';

    protected static ?string $navigationLabel = 'Deposit reconciliation';

    public ?string $deposit = null;

    public bool $isReconciled = false;

    /** @var list<string> */
    public array $discrepancies = [];

    public function mount(?string $deposit = null): void
    {
        $this->verifiedActor();

        if ($deposit !== null) {
            $this->selectDeposit($deposit);
        }
    }

    public function selectDeposit(string $deposit): void
    {
        $this->verifiedActor();
        $record = Deposit::query()->findOrFail($deposit);
        Gate::authorize('view', $record);

        $this->deposit = $record->id;
        $this->refreshReport();
    }

    public function repairMissingCreditAction(): Action
    {
        return Action::make('repairMissingCredit')
            ->label('Repair missing credit')
            ->visible(fn (): bool => in_array('customer_credit_posting', $this->discrepancies, true))
            ->schema([
                Select::make('reason_code')
                    ->options(['missing_credit_posting' => 'Missing credit posting'])
                    ->required(),
            ])
            ->action(function (array $data): void {
                app(RepairMissingCustomerCredit::class)->repair(
                    $this->verifiedActor(),
                    $this->depositRecord(),
                    $data['reason_code'],
                );
                $this->refreshReport();
            });
    }

    public function reverseDepositAction(): Action
    {
        return Action::make('reverseDeposit')
            ->label('Reverse deposit')
            ->color('danger')
            ->visible(fn (): bool => $this->isReconciled)
            ->schema([
                Select::make('reason_code')
                    ->options(['provider_correction' => 'Provider correction'])
                    ->required(),
            ])
            ->requiresConfirmation()
            ->action(function (array $data): void {
                app(ReverseDeposit::class)->reverse(
                    $this->verifiedActor(),
                    $this->depositRecord(),
                    $data['reason_code'],
                );
                $this->refreshReport();
            });
    }

    /** @return array{deposits: Collection<int, Deposit>} */
    protected function getViewData(): array
    {
        return [
            'deposits' => Deposit::query()
                ->latest('received_at')
                ->limit(50)
                ->get(['id', 'kind', 'currency', 'received_at']),
        ];
    }

    private function depositRecord(): Deposit
    {
        abort_unless($this->deposit !== null, 404);

        $deposit = Deposit::query()->findOrFail($this->deposit);
        Gate::authorize('correct', $deposit);

        return $deposit;
    }

    private function verifiedActor(): User
    {
        $actor = auth()->user();
        abort_unless($actor instanceof User, 404);
        Gate::authorize('viewAny', Deposit::class);
        app(FinancialOperatorMfaSession::class)->assertVerified($actor);

        return $actor;
    }

    private function refreshReport(): void
    {
        $report = app(ReconcileDepositAction::class)->report($this->depositRecord());
        $this->isReconciled = $report->isReconciled;
        $this->discrepancies = $report->discrepancies;
    }
}
