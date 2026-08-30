import { Passkeys } from '@laravel/passkeys';

const status = (element, message) => {
    element.textContent = message;
};

document.querySelectorAll('[data-passkey-registration]').forEach((form) => {
    const name = form.querySelector('[data-passkey-name]');
    const message = form.querySelector('[data-passkey-status]');

    if (!Passkeys.isSupported()) {
        form.hidden = true;

        return;
    }

    form.addEventListener('submit', async (event) => {
        event.preventDefault();

        if (name.value.trim() === '') {
            return;
        }

        try {
            await Passkeys.register({ name: name.value.trim() });
            status(message, 'Passkey added.');
            name.value = '';
        } catch {
            status(message, 'The passkey could not be added. Confirm your password and try again.');
        }
    });
});

document.querySelectorAll('[data-passkey-login]').forEach((section) => {
    const button = section.querySelector('[data-passkey-login-button]');
    const message = section.querySelector('[data-passkey-status]');

    if (!Passkeys.isSupported()) {
        return;
    }

    section.hidden = false;

    button.addEventListener('click', async () => {
        try {
            const response = await Passkeys.verify();

            window.location.assign(response.redirect ?? '/operations');
        } catch {
            status(message, 'The passkey sign-in could not be completed. Use your password or recovery flow instead.');
        }
    });
});
