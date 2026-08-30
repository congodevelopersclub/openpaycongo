<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="utf-8">
    <meta name="viewport" content="width=device-width, initial-scale=1">
    <title>Set up OpenPay Congo</title>
</head>
<body>
    <main>
        <h1>Set up OpenPay Congo</h1>
        <p>Create the first administrator, then enroll mandatory two-factor authentication.</p>

        <form method="POST" action="{{ route('setup.initial.store') }}">
            @csrf

            <label for="username">Username</label>
            <input id="username" name="username" type="text" autocomplete="username" required autofocus>

            <label for="name">Name</label>
            <input id="name" name="name" type="text" autocomplete="name" required>

            <label for="email">Email address</label>
            <input id="email" name="email" type="email" autocomplete="email" required>

            <label for="password">Password</label>
            <input id="password" name="password" type="password" autocomplete="new-password" required>

            <label for="password_confirmation">Confirm password</label>
            <input id="password_confirmation" name="password_confirmation" type="password" autocomplete="new-password" required>

            <button type="submit">Create administrator</button>
        </form>
    </main>
</body>
</html>
