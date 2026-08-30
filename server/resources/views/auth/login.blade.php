<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Sign in</title>
</head>
<body>
    <main>
        <h1>Sign in</h1>

        <form method="POST" action="{{ route('login.store') }}">
            @csrf

            <label for="email">Email address</label>
            <input id="email" name="email" type="email" autocomplete="email" required autofocus>

            <label for="password">Password</label>
            <input id="password" name="password" type="password" autocomplete="current-password" required>

            <label>
                <input name="remember" type="checkbox" value="1">
                Remember this device
            </label>

            <button type="submit">Sign in</button>
        </form>

        @if (Route::has('password.request'))
            <p><a href="{{ route('password.request') }}">Recover your account</a></p>
        @endif
    </main>
</body>
</html>
