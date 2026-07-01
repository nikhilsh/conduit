import { defineConfig } from '@playwright/test';

// @appetize/playwright drives appetize.io inside a headless Chromium context
// and exposes an auto-started `session` fixture. baseURL defaults to
// https://appetize.io, so no override is needed here.
export default defineConfig({
  testDir: './tests',
  // One Appetize session at a time: basic plans allow a single concurrent
  // session, and sequential runs keep us safely under any maxConcurrent limit.
  workers: 1,
  fullyParallel: false,
  // Cold-booting a cloud device + launching the app is occasionally slow;
  // one retry absorbs a transient session-start hiccup without masking a
  // real failure (which still fails the job after the retry).
  retries: 1,
  timeout: 180_000,
  expect: { timeout: 30_000 },
  reporter: [['list']],
  use: {
    headless: true,
  },
});
