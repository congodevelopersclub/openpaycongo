import { defineConfig } from '@playwright/test';

export default defineConfig({
    testDir: './tests/Browser',
    testMatch: /.*Test\.js/,
    fullyParallel: false,
    use: {
        baseURL: process.env.BASE_URL ?? 'http://browser-app:8000',
        browserName: 'chromium',
        headless: true,
    },
});
