<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Verify your identity</title>
</head>
<body>
    <main>
        <h1>Verify your identity</h1>
        <p>Enter the code from your authenticator app, or use one recovery code.</p>

        <form method="POST" action="{{ route('two-factor.login.store') }}">
            @csrf

            <label for="code">Authenticator code</label>
            <input id="code" name="code" type="text" inputmode="numeric" autocomplete="one-time-code">

            <button type="submit">Verify code</button>
        </form>

        <form method="POST" action="{{ route('two-factor.login.store') }}">
            @csrf

            <label for="recovery_code">Recovery code</label>
            <input id="recovery_code" name="recovery_code" type="text" autocomplete="off">

            <button type="submit">Use recovery code</button>
        </form>
    </main>
</body>
</html>
