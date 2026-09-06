<x-filament-panels::page>
    <div
        class="space-y-6"
        x-data="{ clientId: null, clientSecret: null }"
        x-on:developer-application-credentials-issued.window="clientId = $event.detail.clientId; clientSecret = $event.detail.clientSecret"
        x-on:developer-application-credentials-cleared.window="clientId = null; clientSecret = null"
    >
        <section aria-labelledby="developer-credentials-heading" class="max-w-4xl rounded-xl border p-4">
            <h2 id="developer-credentials-heading" class="text-lg font-semibold">Developer application credentials</h2>
            <div class="mt-4">
                {{ $this->issueDeveloperApplicationAction }}
            </div>
        </section>

        <section x-cloak x-show="clientSecret !== null" aria-labelledby="developer-secret-heading" class="max-w-4xl rounded-xl border p-4">
            <h2 id="developer-secret-heading" class="text-lg font-semibold">New client secret</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
                Copy this secret now. It is shown only for this issuance or rotation.
            </p>
            <dl class="mt-4 space-y-3 text-sm">
                <div>
                    <dt class="font-medium">Client ID</dt>
                    <dd class="break-all font-mono" x-text="clientId"></dd>
                </div>
                <div>
                    <dt class="font-medium">Client secret</dt>
                    <dd class="break-all font-mono" x-text="clientSecret"></dd>
                </div>
            </dl>
        </section>

        <section aria-labelledby="developer-applications-heading" class="max-w-4xl rounded-xl border p-4">
            <h2 id="developer-applications-heading" class="text-lg font-semibold">Applications</h2>
            <div class="mt-4 overflow-x-auto">
                <table class="w-full text-left text-sm">
                    <thead>
                        <tr class="border-b">
                            <th class="py-2 pr-4 font-medium">Name</th>
                            <th class="py-2 pr-4 font-medium">Scopes</th>
                            <th class="py-2 pr-4 font-medium">Last used</th>
                            <th class="py-2 pr-4 font-medium">Status</th>
                            <th class="py-2 pr-4 font-medium">Actions</th>
                        </tr>
                    </thead>
                    <tbody>
                        @forelse ($this->applications() as $application)
                            <tr class="border-b align-top">
                                <td class="py-3 pr-4">{{ $application->name ?? $application->oauthClient->name }}</td>
                                <td class="py-3 pr-4">{{ implode(', ', $application->oauthClient->scopes ?? []) }}</td>
                                <td class="py-3 pr-4">{{ $application->oauthClient->last_used_at ?? 'Never' }}</td>
                                <td class="py-3 pr-4">{{ $application->oauthClient->revoked ? 'Revoked' : 'Active' }}</td>
                                <td class="flex gap-2 py-3 pr-4">
                                    {{ ($this->rotateDeveloperApplicationAction)(['application' => $application->getKey()]) }}
                                    {{ ($this->revokeDeveloperApplicationAction)(['application' => $application->getKey()]) }}
                                </td>
                            </tr>
                        @empty
                            <tr>
                                <td colspan="5" class="py-3 text-sm text-gray-600 dark:text-gray-400">No developer applications have credentials yet.</td>
                            </tr>
                        @endforelse
                    </tbody>
                </table>
            </div>
        </section>

        <section aria-labelledby="developer-credential-audit-heading" class="max-w-4xl rounded-xl border p-4">
            <h2 id="developer-credential-audit-heading" class="text-lg font-semibold">Audit history</h2>
            <ul class="mt-4 space-y-2 text-sm">
                @forelse ($this->auditHistory() as $audit)
                    <li>{{ $audit->created_at }} - {{ $audit->action }} - {{ implode(', ', $audit->scopes ?? []) }}</li>
                @empty
                    <li class="text-gray-600 dark:text-gray-400">No credential audit events yet.</li>
                @endforelse
            </ul>
        </section>
    </div>
</x-filament-panels::page>
