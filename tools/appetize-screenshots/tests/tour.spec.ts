import { test } from '@appetize/playwright';
import { mkdirSync, writeFileSync } from 'node:fs';
import { join } from 'node:path';

// Captures a short visual tour of each build on Appetize and writes PNGs under
// ./screenshots (uploaded as an artifact by appetize.yml). publicKeys come from
// the upload jobs via env; sessions are publicKey-only (no APPETIZE_TOKEN).
//
// The tour walks the App Store "demo mode" — a fully simulated box + agent
// replies that needs no broker (the "Explore without a server" CTA calls
// SessionStore.activateDemo()). That lets us screenshot the real connected UI
// (home session list + a chat with agent replies and tool cards) which would
// otherwise require a live broker + pairing.
//
// Taps target the shared `text` attribute, which resolves on both iOS and
// Android; the demo strings are byte-identical across platforms (DemoData).
// Each screenshot is taken as soon as its screen renders, so if a later tap
// fails the earlier captures are still written — appetize.yml uploads the
// artifact with always().

const OUT_DIR = join(process.cwd(), 'screenshots');
mkdirSync(OUT_DIR, { recursive: true });

const TARGETS = [
  { platform: 'ios', publicKey: process.env.IOS_PUBLIC_KEY },
  { platform: 'android', publicKey: process.env.ANDROID_PUBLIC_KEY },
];

for (const { platform, publicKey } of TARGETS) {
  if (!publicKey) continue;

  test.describe(platform, () => {
    // Dark = the design mockups' hero look. The app follows system appearance
    // (themeMode defaults to System), so set the session appearance to dark.
    test.use({ config: { publicKey, appearance: 'dark' } });

    test(`${platform} tour`, async ({ session }) => {
      const shot = async (name: string) => {
        const png = await session.screenshot('buffer');
        writeFileSync(join(OUT_DIR, `${platform}-${name}.png`), png.data);
      };

      // Belt-and-suspenders: also force dark at runtime in case the config
      // appearance didn't apply before first launch.
      await session.setAppearance('dark');

      // 1. Onboarding welcome — let the freshly-launched app settle + render.
      await session.waitForTimeout(15_000);
      await shot('onboarding');

      // 2. Demo mode = a simulated box, no broker (App Store reviewer path).
      await session.tap({ element: { attributes: { text: 'Explore without a server' } } });
      await session.waitForTimeout(6_000);
      await shot('demo-home');

      // 3. A session's chat — agent replies + tool cards.
      await session.tap({ element: { attributes: { text: 'Build a to-do app' } } });
      await session.waitForTimeout(5_000);
      await shot('demo-chat');
    });
  });
}
