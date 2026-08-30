<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Secure your administrator account</title>
    @if (! app()->environment('testing'))
        @vite(['resources/js/app.js'])
    @endif
</head>
<body>
    <main>
        <h1>Secure your administrator account</h1>
        <p>Two-factor authentication is required before financial operations can be accessed.</p>

        <ol>
            <li><a href="{{ route('password.confirm') }}">Confirm your password</a> before changing authentication settings.</li>
            <li>
                <form method="POST" action="{{ route('two-factor.enable') }}">
                    @csrf
                    <button type="submit">Enable authenticator app</button>
                </form>
            </li>
            <li><a href="{{ route('two-factor.qr-code') }}">Open the QR code in your authenticator app</a>.</li>
            <li>
                <form method="POST" action="{{ route('two-factor.confirm') }}">
                    @csrf
                    <label for="code">Authenticator code</label>
                    <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code" required>
                    <button type="submit">Confirm authenticator app</button>
                </form>
            </li>
        </ol>

        @if ($user->two_factor_confirmed_at !== null)
            <section>
                <h2>Recovery codes</h2>
                <p>Store the recovery codes before continuing. They are shown only by the authenticated Fortify endpoint.</p>
                <p><a href="{{ route('two-factor.recovery-codes') }}">Open recovery codes</a></p>

                <form method="POST" action="{{ route('setup.recovery-codes.acknowledge') }}">
                    @csrf
                    <label>
                        <input name="recovery_codes_saved" type="checkbox" value="1" required>
                        I have stored my recovery codes securely.
                    </label>
                    <button type="submit">Continue</button>
                </form>
            </section>
        @endif

        @if ($passkeysAvailable)
            <section>
                <h2>Passkeys</h2>
                <p>Passkeys are strongly recommended as an additional sign-in method. Your password and recovery flow remain available.</p>
                <p>Confirm your password before adding or removing a passkey.</p>

                <form data-passkey-registration>
                    <label for="passkey_name">Passkey name</label>
                    <input id="passkey_name" data-passkey-name type="text" maxlength="120" required>
                    <button type="submit">Add passkey</button>
                    <p data-passkey-status aria-live="polite"></p>
                </form>

                @if ($passkeys->isNotEmpty())
                    <h3>Your passkeys</h3>
                    <ul>
                        @foreach ($passkeys as $passkey)
                            <li>
                                {{ $passkey->name }}
                                @if ($passkey->last_used_at !== null)
                                    (last used {{ $passkey->last_used_at->toDateString() }})
                                @endif
                                <form method="POST" action="{{ route('passkey.destroy', $passkey) }}">
                                    @csrf
                                    @method('DELETE')
                                    <button type="submit">Remove passkey</button>
                                </form>
                            </li>
                        @endforeach
                    </ul>
                @endif
            </section>
        @endif
    </main>
</body>
</html>
