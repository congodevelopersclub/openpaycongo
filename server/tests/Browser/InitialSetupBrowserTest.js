import { expect, test } from '@playwright/test';

test.describe.configure({ mode: 'serial' });

test('first setup closes replay, requires TOTP, and withholds passkey enrollment until TOTP confirmation', async ({ page }) => {
    await page.goto('/setup');
    await expect(page.getByRole('heading', { name: 'Set up OpenPay Congo' })).toBeVisible();
    await page.getByLabel('Username').fill('browser-admin');
    await page.getByLabel('Name', { exact: true }).fill('Browser Administrator');
    await page.getByLabel('Email address').fill('browser-admin@example.test');
    await page.getByLabel('Password', { exact: true }).fill('correct-horse-battery-staple');
    await page.getByLabel('Confirm password').fill('correct-horse-battery-staple');
    await page.getByRole('button', { name: 'Create administrator' }).click();

    await expect(page).toHaveURL(/\/setup\/security$/);
    await expect(page.getByText('Two-factor authentication is required before financial operations can be accessed.')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Add passkey' })).toHaveCount(0);

    const operations = await page.goto('/operations/reconcile-deposit');
    expect(operations?.status()).toBe(404);

    const replay = await page.goto('/setup');
    expect(replay?.status()).toBe(404);
});
