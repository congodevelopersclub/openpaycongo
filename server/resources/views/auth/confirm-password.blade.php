<!doctype html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Confirm your password</title>
</head>
<body>
    <main>
        <h1>Confirm your password</h1>
        <p>Confirm your password before changing authentication settings.</p>

        <form method="POST" action="{{ route('password.confirm.store') }}">
            @csrf

            <label for="password">Password</label>
            <input id="password" name="password" type="password" autocomplete="current-password" required autofocus>

            <button type="submit">Confirm password</button>
        </form>
    </main>
</body>
</html>
