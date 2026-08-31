<x-filament-panels::page>
    <div class="space-y-6">
        <section aria-labelledby="pairing-intent-heading" class="max-w-xl rounded-xl border p-4">
            <h2 id="pairing-intent-heading" class="text-lg font-semibold">Pair a mobile device</h2>
            <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">
                Create a short-lived QR code for a mobile device. It expires automatically and can be scanned only during its selected lifetime.
            </p>
            <div class="mt-4">
                {{ $this->issuePairingIntentAction }}
            </div>
        </section>

        @if ($qrSvg !== null)
            <section aria-labelledby="pairing-qr-heading" class="max-w-xl rounded-xl border p-4">
                <h2 id="pairing-qr-heading" class="text-lg font-semibold">Pairing QR code</h2>
                <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">Scan this QR code with the OpenPay Congo mobile app.</p>
                <p class="mt-2 text-sm text-gray-600 dark:text-gray-400">The mobile app verifies this signed QR. Issuing it does not complete pairing or issue credentials.</p>
                <div class="mt-4 w-fit bg-white p-3" role="img" aria-label="Signed OpenPay Congo mobile-pairing QR code">
                    {!! $qrSvg !!}
                </div>
            </section>
        @endif
    </div>
</x-filament-panels::page>
