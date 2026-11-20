import { defineConfig } from '@playwright/test';

export default defineConfig({
  testDir: './tests/browser',
  workers: 1,
  timeout: 45_000,
  use: {
    baseURL: 'http://127.0.0.1:4322',
    launchOptions: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {},
  },
  webServer: {
    command: 'pnpm exec astro preview --host 127.0.0.1 --port 4322',
    url: 'http://127.0.0.1:4322/flexr/playground/',
    timeout: 30_000,
  },
});
