<x-filament-panels::page>
    <div class="space-y-6">
        <section aria-labelledby="operator-sms-pattern-actions" class="max-w-4xl rounded-xl border p-4">
            <h2 id="operator-sms-pattern-actions" class="text-lg font-semibold">Manual proposals, approval and release</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
                Proposals are review-only. An MFA-verified financial operator must approve a proposal before another action can issue a signed mobile release.
            </p>
            <div class="mt-4 flex flex-wrap gap-3">
                {{ $this->proposePatternAction }}
                {{ $this->approvePatternAction }}
                {{ $this->releasePatternAction }}
            </div>
        </section>

        <section aria-labelledby="operator-sms-pattern-proposals" class="max-w-6xl rounded-xl border p-4">
            <h2 id="operator-sms-pattern-proposals" class="text-lg font-semibold">Pattern proposals</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Raw SMS is not collected or shown here.</p>
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

        <section aria-labelledby="operator-sms-pattern-releases" class="max-w-6xl rounded-xl border p-4">
            <h2 id="operator-sms-pattern-releases" class="text-lg font-semibold">Signed release exports</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Copy the canonical JSON into the paired mobile app’s signed-pattern import flow. The authenticated pattern-release endpoint is also available to mobile clients.</p>
            <div class="mt-4 space-y-4">
                @forelse ($this->releases() as $release)
                    <article class="rounded-lg border p-3">
                        <p class="mb-2 text-sm">{{ $release->provider }} / {{ $release->sender }} / version {{ $release->pattern_version }} / expires {{ $release->expires_at }}</p>
                        <textarea aria-label="Signed release JSON" class="w-full font-mono text-xs" rows="8" readonly>{{ $release->encoded_release }}</textarea>
                    </article>
                @empty
                    <p class="text-sm text-gray-600 dark:text-gray-400">No signed releases have been published.</p>
                @endforelse
            </div>
        </section>
    </div>
</x-filament-panels::page>
