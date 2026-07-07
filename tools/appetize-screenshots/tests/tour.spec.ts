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
    // (themeMode defaults to System), so run the session in dark.
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

      // 2a. Flow Start sheet — opened via the FLOWS header's "+ New flow"
      // text action (not the bottom-bar icon-only "+" pill, which has no
      // `text` attribute for Appetize to target; the header action reaches
      // the same real ConduitFlowStartSheet/FlowStartSheet with zero
      // network). It opens with the Flow tab already selected; tapping
      // "Flow" again exercises the segmented control same as a reviewer
      // would.
      await session.tap({ element: { attributes: { text: 'New flow' } } });
      await session.waitForTimeout(3_000);
      await session.tap({ element: { attributes: { text: 'Flow' } } });
      await session.waitForTimeout(2_000);
      await shot('demo-flow-start');

      // 2b. Pick the "Research → Design → Build" built-in recipe. Demo mode
      // forces the wizard to open on the Task screen (this template's real
      // prefill jumps straight to Steps) so the tour shows both screens —
      // the task field arrives pre-filled with the template's own task
      // string, so "Next" is enabled with no typing required.
      await session.tap({ element: { attributes: { text: 'Research → Design → Build' } } });
      await session.waitForTimeout(3_000);
      await shot('demo-flow-wizard-task');

      await session.tap({ element: { attributes: { text: 'Next · choose steps' } } });
      await session.waitForTimeout(2_000);
      await shot('demo-flow-wizard-steps');

      // 2c. Step editor — tap the first step card, screenshot, "Done" back
      // to Steps.
      await session.tap({ element: { attributes: { text: '1. Research' } } });
      await session.waitForTimeout(2_500);
      await shot('demo-flow-step-editor');
      await session.tap({ element: { attributes: { text: 'Done' } } });
      await session.waitForTimeout(1_500);

      // 2d. Add step → If/Else branch editor, then Discard so no fake flow
      // is left half-built (the wizard's real "Start flow" no-network path
      // is exercised separately, not by this tour). The built-in recipe is
      // always exactly 3 steps, so the appended branch is deterministically
      // step 4 — "4. If / Else" targets the new step card, not the "Add
      // step" pill choice (bare "If / Else").
      await session.tap({ element: { attributes: { text: 'Add step' } } });
      await session.waitForTimeout(1_000);
      await session.tap({ element: { attributes: { text: 'If / Else' } } });
      await session.waitForTimeout(1_000);
      await session.tap({ element: { attributes: { text: '4. If / Else' } } });
      await session.waitForTimeout(2_000);
      await shot('demo-flow-branch');
      await session.tap({ element: { attributes: { text: 'Discard' } } });
      await session.waitForTimeout(1_500);

      // 2e. Dismiss the wizard — back to demo home. No fake flow was
      // started, so the existing flow-monitor tap target below (the
      // `demo-flow-1` fixture card) is unaffected.
      //
      // Android: two elements match text "Cancel" here. Per code audit
      // (FlowWizardScreen.kt AddStepControl), the add-step pill row's own
      // "Cancel" pill is NOT the cause — `onBranchStep` already collapses
      // `addStepMenuExpanded` back to false the moment "If / Else" is
      // tapped (step 2d above), before the branch editor even opens. The
      // only "Cancel" text that should exist at this point is the wizard's
      // own nav-bar `TextButton`, so the second match is a residual
      // accessibility node from the branch editor `Dialog` window Appetize
      // observed mid-teardown, not a live tappable duplicate. matchIndex
      // pins the tap to the nav-bar Cancel (topmost in composition order,
      // the one guaranteed to be live) rather than guessing which node wins.
      await session.tap({ element: { attributes: { text: 'Cancel' } } }, { matchIndex: 0 });
      await session.waitForTimeout(2_500);

      // 2f. Flow monitor — demo home's FLOWS section seeds two fixture
      // pipelines (DemoData.pipelines); this one is `awaiting_gate`, so the
      // gate review card should be visible in the shot.
      await session.tap({ element: { attributes: { text: 'Add rate limiter to broker' } } });
      await session.waitForTimeout(5_000);
      await shot('demo-flow-monitor');

      // Back to demo home — "Home" is demo-fixture-only chrome on the
      // Monitor's toolbar (the real Monitor has no text-labeled back
      // affordance to tap; see ConduitPipelineMonitorView.swift /
      // PipelineMonitorScreen.kt).
      // matchIndex: Android's element dump reports two "Home" matches at this
      // point (the toolbar button plus an occluded element under the overlay);
      // index 0 is the visible toolbar button, first in the tree. Per the
      // @appetize/playwright types (session.tap(args, options) --
      // PlayActionOptions.matchIndex), matchIndex is a SECOND-argument
      // option, not a sibling of `element` in the first arg -- the same
      // shape already used for the "Cancel" tap above.
      await session.tap({ element: { attributes: { text: 'Home' } } }, { matchIndex: 0 });
      await session.waitForTimeout(3_000);

      // 3. A session's chat — agent replies + tool cards.
      await session.tap({ element: { attributes: { text: 'Build a to-do app' } } });
      await session.waitForTimeout(5_000);
      await shot('demo-chat');

      // 4. Terminal tab — faux shell output. matchIndex: with the pill
      // segments' pinned accessibility labels (#941) iOS reports a second
      // "Terminal" match from the demo chat content; index 0 is the tab
      // pill (first in the tree).
      await session.tap({ element: { attributes: { text: 'Terminal' } } }, { matchIndex: 0 });
      await session.waitForTimeout(3_000);
      await shot('demo-terminal');

      // 5. Browser tab — bundled preview.html in a WebView (allow load time).
      await session.tap({ element: { attributes: { text: 'Browser' } } }, { matchIndex: 0 });
      await session.waitForTimeout(6_000);
      await shot('demo-browser');
    });
  });
}
