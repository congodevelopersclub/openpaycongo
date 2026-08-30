<x-filament-panels::page>
    <div class="space-y-6">
        <section aria-label="Deposits">
            <h2 class="text-lg font-semibold">Deposits</h2>
            <ul class="mt-3 divide-y rounded-xl border">
                @foreach ($deposits as $candidate)
                    <li class="flex items-center justify-between p-3">
                        <span>{{ $candidate->kind }} · {{ $candidate->currency }}</span>
                        <x-filament::button wire:click="selectDeposit('{{ $candidate->id }}')" size="sm">
                            View reconciliation
                        </x-filament::button>
                    </li>
                @endforeach
            </ul>
        </section>

        @if ($deposit !== null)
            <section aria-label="Reconciliation report" class="rounded-xl border p-4">
                <h2 class="text-lg font-semibold">{{ $isReconciled ? 'Reconciled' : 'Discrepancies found' }}</h2>
                @if ($discrepancies !== [])
                    <ul class="mt-3 list-disc pl-5">
                        @foreach ($discrepancies as $discrepancy)
                            <li>{{ $discrepancy }}</li>
                        @endforeach
                    </ul>
                @endif
                <div class="mt-4 flex gap-3">
                    {{ $this->repairMissingCreditAction }}
                    {{ $this->reverseDepositAction }}
                </div>
            </section>
        @endif
    </div>
</x-filament-panels::page>
