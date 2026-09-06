<x-filament-panels::page>
    <div class="space-y-6">
        <section aria-labelledby="operator-sms-pattern-actions" class="max-w-4xl rounded-xl border p-4">
            <h2 id="operator-sms-pattern-actions" class="text-lg font-semibold">Developer approval and release</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
                Gemma proposals are review-only. Approval does not change mobile parsing; only a subsequent signed release can be downloaded by a paired device.
            </p>
            <div class="mt-4 flex flex-wrap gap-3">
                {{ $this->approvePatternAction }}
                {{ $this->releasePatternAction }}
            </div>
        </section>

        <section aria-labelledby="operator-sms-pattern-proposals" class="max-w-6xl rounded-xl border p-4">
            <h2 id="operator-sms-pattern-proposals" class="text-lg font-semibold">Pattern proposals</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Raw SMS evidence is intentionally unavailable on this page.</p>
            <div class="mt-4 overflow-x-auto">
                <table class="w-full text-left text-sm">
                    <thead><tr class="border-b"><th class="py-2 pr-4">Provider</th><th class="py-2 pr-4">Sender</th><th class="py-2 pr-4">Template</th><th class="py-2 pr-4">Status</th><th class="py-2">Reviewed</th></tr></thead>
                    <tbody>
                        @forelse ($this->proposals() as $proposal)
                            <tr class="border-b align-top"><td class="py-3 pr-4">{{ $proposal->provider }}</td><td class="py-3 pr-4">{{ $proposal->sender }}</td><td class="py-3 pr-4 font-mono">{{ $proposal->template }}</td><td class="py-3 pr-4">{{ $proposal->status }}</td><td class="py-3">{{ $proposal->reviewed_at ?? 'Not reviewed' }}</td></tr>
                        @empty
                            <tr><td colspan="5" class="py-3 text-gray-600 dark:text-gray-400">No proposals are awaiting review.</td></tr>
                        @endforelse
                    </tbody>
                </table>
            </div>
        </section>
    </div>
</x-filament-panels::page>
