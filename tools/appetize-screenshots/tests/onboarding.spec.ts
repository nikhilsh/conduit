import { test } from '@appetize/playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Captures the app's first (onboarding) screen on Appetize for each platform
// and writes a PNG under ./screenshots, which the appetize.yml workflow uploads
// as an artifact. The publicKeys come from the upload jobs via env.
//
// Notes:
//  - The `session` fixture auto-starts the Appetize session and launches the
//    app once `config.publicKey` is set via test.use(); no explicit
//    client.startSession() call is needed.
//  - Auth is publicKey-only — the REST APPETIZE_TOKEN is NOT required to run a
//    session.
//  - device/osVersion are deliberately NOT pinned: the iOS app targets iOS 26,
//    so we let Appetize pick a compatible default device rather than risk an
//    unavailable device/OS combination. Pin them here later if a specific
//    frame is wanted (and confirmed available on the plan).

const OUT_DIR = join(process.cwd(), 'screenshots');
mkdirSync(OUT_DIR, { recursive: true });

const TARGETS = [
  { platform: 'ios', publicKey: process.env.IOS_PUBLIC_KEY },
  { platform: 'android', publicKey: process.env.ANDROID_PUBLIC_KEY },
];

for (const { platform, publicKey } of TARGETS) {
  if (!publicKey) continue; // e.g. that platform's upload job was skipped

  test.describe(platform, () => {
    test.use({ config: { publicKey } });

    test(`${platform} onboarding`, async ({ session }) => {
      // Let the freshly-launched app settle and render its first screen.
      await session.waitForTimeout(15_000);
      const shot = await session.screenshot('buffer');
      writeFileSync(join(OUT_DIR, `${platform}-onboarding.png`), shot.data);
    });
  });
}
