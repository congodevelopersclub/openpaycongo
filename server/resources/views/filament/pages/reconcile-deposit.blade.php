<x-filament-panels::page>
    <div class="space-y-6">
        <section aria-label="Deposits">
            <h2 class="text-lg font-semibold">Deposits</h2>
            <p class="mt-2 text-sm">SMS-backed credit is provisional. Receipt and reconciliation do not prove provider settlement.</p>
            <ul class="mt-3 divide-y rounded-xl border">
                @foreach ($deposits as $candidate)
                    <li class="flex items-center justify-between p-3">
                        <span>{{ $candidate->kind }} · {{ $candidate->currency }}</span>
                        <x-filament::button wire:click="selectDeposit('{{ $candidate->id }}')" size="sm">
                            {{ $candidate->amount_minor }} minor units. Customer {{ $candidate->customer_id }}.
                            View reconciliation
                        </x-filament::button>
                    </li>
                @endforeach
            </ul>
        </section>

        @if ($deposit !== null)
            <section aria-label="Reconciliation report" class="rounded-xl border p-4">
                <h2 class="text-lg font-semibold">{{ $isReconciled ? 'Reconciled' : 'Discrepancies found' }}</h2>
                @if ($selectedDeposit !== null)
                    <dl class="mt-3 space-y-2 text-sm">
                        <div><dt>Customer reference</dt><dd>{{ $selectedDeposit->customer_id }}</dd></div>
                        <div><dt>Source installation</dt><dd>{{ $selectedDeposit->source_installation_id }}</dd></div>
                        <div><dt>Provider occurrence</dt><dd>{{ $selectedDeposit->provider_occurred_at }}</dd></div>
                        <div><dt>Available credit in minor units</dt><dd>{{ $availableMinor ?? 'Posting pending' }} {{ $selectedDeposit->currency }}</dd></div>
                        <div><dt>Settlement status</dt><dd>Unverified</dd></div>
                        <div><dt>Parser release</dt><dd>{{ $selectedDeposit->parser_evidence['parser_release_id'] ?? 'Legacy ingress without parser evidence' }}</dd></div>
                    </dl>
                @endif
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
