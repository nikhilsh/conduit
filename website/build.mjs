#!/usr/bin/env node
// build.mjs — static-site generator for conduit.
//
// Replaces the prior Next.js setup. The site is one HTML page that's
// just download links + current-release info; React/Next added 87KB
// of bundle for nothing visible.
//
// Output: website/out/{index.html, manifest.plist, .deploy.yaml}.
// `fyra push` from website/out/ ships it.

import { mkdir, writeFile, copyFile, access } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(__dirname, "out");
const publicDir = path.join(__dirname, "public");

const repo = process.env.GITHUB_REPO || "nikhilsh/conduit";
const siteOrigin = process.env.SITE_ORIGIN || "https://conduit.kaopeh.com";

const headers = {
    "User-Agent": "conduit-website-build",
    Accept: "application/vnd.github+json",
};
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
if (token) headers.Authorization = `Bearer ${token}`;

async function fetchLatestRelease() {
    const res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, { headers });
    if (!res.ok) throw new Error(`github releases fetch: ${res.status}`);
    const releases = await res.json();
    if (!Array.isArray(releases) || releases.length === 0) throw new Error("no releases");

    releases.sort((a, b) => new Date(b.published_at) - new Date(a.published_at));

    const isPublished = (r) => !r.draft && !r.prerelease;
    const hasIpa = (r) => (r.assets || []).some((a) => a.name === "Conduit.ipa");
    const r =
        releases.find((x) => isPublished(x) && hasIpa(x)) ||
        releases.find((x) => !x.draft && hasIpa(x)) ||
        releases.find(isPublished) ||
        releases.find((x) => !x.draft) ||
        releases[0];

    const assets = r.assets || [];
    return {
        tagName: r.tag_name,
        releaseName: r.name,
        releaseUrl: r.html_url,
        publishedAt: r.published_at,
        ipa: assets.find((a) => a.name === "Conduit.ipa"),
        apk: assets.find((a) => a.name.endsWith(".apk")),
    };
}

function manifestPlist(ipa, tag) {
    return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>items</key>
  <array>
    <dict>
      <key>assets</key>
      <array>
        <dict>
          <key>kind</key>
          <string>software-package</string>
          <key>url</key>
          <string>${ipa.browser_download_url}</string>
        </dict>
      </array>
      <key>metadata</key>
      <dict>
        <key>bundle-identifier</key>
        <string>sh.nikhil.conduit</string>
        <key>bundle-version</key>
        <string>${tag}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>Conduit</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
}

function htmlPage({ tagName, publishedAt, releaseUrl, ipa, apk, manifestUrl, otaInstallUrl }) {
    const repoUrl = `https://github.com/${repo}`;
    const docsUrl = `${repoUrl}/tree/main/docs`;
    const installScriptUrl = `${repoUrl}/releases/download/${tagName}/install.sh`;
    const installOneLiner = `curl -sSL ${installScriptUrl} | sudo sh -s -- --service --addr :1977 --local`;

    return `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1,viewport-fit=cover">
<title>Conduit — your coding agents, in your pocket</title>
<meta name="description" content="Conduit is a mobile + tablet client for driving your coding agents — Claude and Codex — on your own dev box.">
<meta name="theme-color" content="#04050a" media="(prefers-color-scheme: dark)">
<meta name="theme-color" content="#fafafa" media="(prefers-color-scheme: light)">
<link rel="icon" type="image/png" sizes="32x32" href="/favicon.png">
<link rel="apple-touch-icon" sizes="192x192" href="/icon-192.png">
<style>
  :root {
    color-scheme: light dark;
    --bg: #ffffff;
    --bg-tint: #f7f8fa;
    --fg: #0a0a0a;
    --fg-soft: #2d2d2d;
    --muted: #6b6b6b;
    --card: rgba(255, 255, 255, 0.6);
    --card-hover: rgba(255, 255, 255, 0.85);
    --border: #e5e7eb;
    --border-strong: #d1d5db;
    --accent: #00a86b;
    --accent-soft: rgba(0, 168, 107, 0.10);
    --accent-text: #ffffff;
    --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.04);
    --shadow-md: 0 4px 12px rgba(0, 0, 0, 0.05);
  }
  @media (prefers-color-scheme: dark) {
    :root {
      --bg: #0a0c10;
      --bg-tint: #11141a;
      --fg: #f5f5f5;
      --fg-soft: #d4d4d4;
      --muted: #888c93;
      --card: rgba(255, 255, 255, 0.035);
      --card-hover: rgba(255, 255, 255, 0.06);
      --border: rgba(255, 255, 255, 0.08);
      --border-strong: rgba(255, 255, 255, 0.14);
      --accent: #34c759;
      --accent-soft: rgba(52, 199, 89, 0.14);
      --accent-text: #06090d;
      --shadow-sm: 0 1px 2px rgba(0, 0, 0, 0.25);
      --shadow-md: 0 8px 24px rgba(0, 0, 0, 0.35);
    }
  }
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
  html, body { margin: 0; padding: 0; background: var(--bg); color: var(--fg); }
  body {
    font: 16px/1.55 -apple-system, BlinkMacSystemFont, "SF Pro Text", "Segoe UI", Roboto, "Helvetica Neue", Arial, sans-serif;
    -webkit-font-smoothing: antialiased;
    -moz-osx-font-smoothing: grayscale;
    min-height: 100vh;
    display: flex;
    flex-direction: column;
    background:
      radial-gradient(1100px 500px at 50% -200px, var(--accent-soft), transparent 70%),
      var(--bg);
  }
  main {
    width: 100%;
    max-width: 560px;
    margin: 0 auto;
    padding: clamp(28px, 6vw, 64px) clamp(18px, 5vw, 28px) 28px;
    flex: 1;
  }

  /* --- hero --- */
  .hero {
    display: flex;
    align-items: center;
    gap: 14px;
    margin-bottom: clamp(10px, 2vw, 18px);
  }
  .mark {
    width: 56px; height: 56px;
    border-radius: 14px;
    overflow: hidden;
    box-shadow: var(--shadow-md);
    flex-shrink: 0;
  }
  .mark img { width: 100%; height: 100%; display: block; }
  h1 {
    font-size: clamp(28px, 6vw, 36px);
    line-height: 1.05;
    margin: 0;
    letter-spacing: -0.025em;
    font-weight: 700;
  }
  .tagline {
    color: var(--muted);
    margin: 0 0 clamp(20px, 4vw, 32px);
    font-size: clamp(14px, 3.5vw, 16px);
    line-height: 1.5;
  }

  /* --- release pill --- */
  .release {
    display: inline-flex;
    align-items: center;
    flex-wrap: wrap;
    gap: 6px 8px;
    padding: 8px 14px 8px 10px;
    border-radius: 14px;
    background: var(--accent-soft);
    color: var(--fg-soft);
    font-size: 13px;
    line-height: 1.35;
    margin-bottom: clamp(20px, 5vw, 32px);
    font-feature-settings: "tnum";
    max-width: 100%;
  }
  .release .dot {
    width: 8px; height: 8px;
    border-radius: 50%;
    background: var(--accent);
    box-shadow: 0 0 0 3px var(--accent-soft);
    flex-shrink: 0;
  }
  .release strong {
    color: var(--fg);
    font-weight: 600;
    word-break: break-all;
    /* Long release tags like "manual-2026-05-20-polish3" can break at
       the hyphens on narrow screens rather than overflowing. */
  }
  .release .sep { color: var(--muted); }
  .release .when { color: var(--muted); }

  /* --- sections --- */
  section { margin-bottom: clamp(22px, 5vw, 36px); }
  .label {
    font-size: 11px;
    text-transform: uppercase;
    letter-spacing: 0.10em;
    color: var(--muted);
    margin: 0 0 10px;
    font-weight: 600;
  }

  /* --- buttons --- */
  .actions { display: flex; flex-direction: column; gap: 10px; }
  a.btn {
    display: flex;
    align-items: center;
    gap: 14px;
    padding: 14px 16px;
    border-radius: 14px;
    border: 1px solid var(--border);
    background: var(--card);
    backdrop-filter: blur(8px);
    -webkit-backdrop-filter: blur(8px);
    color: var(--fg);
    text-decoration: none;
    font-weight: 500;
    font-size: 15px;
    box-shadow: var(--shadow-sm);
    transition: border-color 120ms, background 120ms, transform 120ms;
  }
  a.btn:hover, a.btn:focus-visible {
    border-color: var(--border-strong);
    background: var(--card-hover);
    outline: none;
  }
  a.btn:active { transform: scale(0.99); }
  a.btn.primary {
    background: var(--accent);
    color: var(--accent-text);
    border-color: var(--accent);
    font-weight: 600;
  }
  a.btn.primary:hover { background: var(--accent); filter: brightness(1.05); }
  a.btn .icon {
    width: 24px; height: 24px;
    display: grid; place-items: center;
    flex-shrink: 0;
  }
  a.btn .icon svg { width: 22px; height: 22px; }
  a.btn .label-stack { display: flex; flex-direction: column; gap: 2px; min-width: 0; }
  a.btn .label-stack small {
    font-weight: 400;
    font-size: 12px;
    opacity: 0.72;
    line-height: 1.3;
  }
  a.btn .arrow {
    margin-left: auto;
    opacity: 0.5;
    font-size: 17px;
    flex-shrink: 0;
  }
  a.btn:hover .arrow { opacity: 0.85; }

  /* --- inline link grid (compact) --- */
  .links {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
    gap: 8px;
  }
  a.btn.compact {
    padding: 12px 14px;
    font-size: 14px;
  }

  /* --- code block --- */
  pre {
    background: var(--bg-tint);
    border: 1px solid var(--border);
    border-radius: 14px;
    padding: 12px 14px;
    font: 12.5px/1.55 ui-monospace, "SF Mono", "JetBrains Mono", Menlo, Consolas, monospace;
    overflow-x: auto;
    margin: 0;
    color: var(--fg-soft);
    -webkit-overflow-scrolling: touch;
    position: relative;
  }
  pre code { white-space: pre; }

  /* --- footer --- */
  footer {
    text-align: center;
    padding: 24px 20px max(env(safe-area-inset-bottom), 28px);
    font-size: 13px;
    color: var(--muted);
  }
  footer a {
    color: var(--muted);
    text-decoration: none;
    padding: 4px 6px;
  }
  footer a:hover { color: var(--fg); }
  footer .sep { opacity: 0.4; margin: 0 2px; }
</style>
</head>
<body>
<main>
  <header class="hero">
    <div class="mark" aria-hidden="true">
      <img src="/icon-128.png" width="56" height="56" alt="">
    </div>
    <h1>Conduit</h1>
  </header>

  <p class="tagline">Your agents, in your pocket.</p>

  <div class="release" id="release" data-published="${publishedAt}">
    <span class="dot" aria-hidden="true"></span>
    <strong>${tagName}</strong>
    <span class="sep">·</span>
    <span class="when"><time datetime="${publishedAt}">${publishedAt}</time></span>
  </div>

  <section>
    <h2 class="label">Install</h2>
    <div class="actions">
      ${ipa ? `<a class="btn primary" href="${otaInstallUrl}">
        <span class="icon"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.05 12.04c-.02-2.4 1.96-3.55 2.05-3.6-1.12-1.64-2.86-1.87-3.48-1.9-1.48-.15-2.89.87-3.65.87-.76 0-1.92-.85-3.16-.83-1.62.03-3.12.95-3.95 2.4-1.69 2.93-.43 7.26 1.21 9.64.8 1.16 1.75 2.46 3 2.42 1.21-.05 1.66-.78 3.13-.78 1.46 0 1.87.78 3.14.75 1.3-.02 2.12-1.18 2.91-2.36.92-1.35 1.3-2.66 1.32-2.73-.03-.01-2.53-.97-2.55-3.85zM14.62 4.55c.66-.8 1.11-1.91.99-3.02-.96.04-2.12.64-2.81 1.43-.62.71-1.16 1.84-1.02 2.93 1.07.08 2.17-.55 2.84-1.34z"/></svg></span>
        <div class="label-stack">
          <span>Install on iPhone / iPad</span>
          <small>OTA via this site · ad-hoc signed</small>
        </div>
        <span class="arrow">→</span>
      </a>` : ""}
      ${ipa ? `<a class="btn" href="${ipa.browser_download_url}">
        <span class="icon"><svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"><path d="M21 15v4a2 2 0 0 1-2 2H5a2 2 0 0 1-2-2v-4"/><polyline points="7 10 12 15 17 10"/><line x1="12" y1="15" x2="12" y2="3"/></svg></span>
        <div class="label-stack">
          <span>Download IPA</span>
          <small>Sideload with AltStore / Sideloadly</small>
        </div>
        <span class="arrow">↓</span>
      </a>` : ""}
      ${apk ? `<a class="btn" href="${apk.browser_download_url}">
        <span class="icon"><svg viewBox="0 0 24 24" fill="currentColor"><path d="M17.6 9.48l1.84-3.18a.4.4 0 1 0-.69-.4l-1.86 3.22A11.05 11.05 0 0 0 12 8c-1.8 0-3.5.4-4.9 1.12L5.25 5.9a.4.4 0 1 0-.69.4l1.84 3.18A10.43 10.43 0 0 0 1 18h22a10.43 10.43 0 0 0-5.4-8.52zM7 15.25a.94.94 0 1 1 0-1.88.94.94 0 0 1 0 1.88zm10 0a.94.94 0 1 1 0-1.88.94.94 0 0 1 0 1.88z"/></svg></span>
        <div class="label-stack">
          <span>Download APK</span>
          <small>Android sideload</small>
        </div>
        <span class="arrow">↓</span>
      </a>` : ""}
    </div>
  </section>

  <section>
    <h2 class="label">Run the server</h2>
    <pre><code>${installOneLiner}</code></pre>
  </section>

  <section>
    <h2 class="label">More</h2>
    <div class="links">
      <a class="btn compact" href="${releaseUrl}">Release notes <span class="arrow">↗</span></a>
      <a class="btn compact" href="${repoUrl}">GitHub <span class="arrow">↗</span></a>
      <a class="btn compact" href="${docsUrl}">Docs <span class="arrow">↗</span></a>
    </div>
  </section>
</main>

<footer>
  <a href="${repoUrl}">github</a><span class="sep">·</span>
  <a href="${docsUrl}">docs</a><span class="sep">·</span>
  <a href="${repoUrl}/issues">issues</a>
</footer>

<script>
  // Format the publish timestamp in the visitor's local timezone.
  // (The server clock is UTC, so SSR-time formatting would just echo UTC.)
  (function () {
    var el = document.getElementById('release');
    if (!el) return;
    var iso = el.getAttribute('data-published');
    if (!iso) return;
    var d = new Date(iso);
    if (isNaN(d)) return;
    var fmt = d.toLocaleString(undefined, {
      year: 'numeric', month: 'short', day: 'numeric',
      hour: 'numeric', minute: '2-digit',
    });
    var when = el.querySelector('.when');
    if (when) {
      when.innerHTML = '<time datetime="' + iso + '">' + fmt + '</time>';
    }
  })();
</script>
</body>
</html>
`;
}

async function build() {
    const r = await fetchLatestRelease();
    const manifestUrl = `${siteOrigin}/manifest.plist`;
    const otaInstallUrl = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;

    await mkdir(outDir, { recursive: true });

    await writeFile(
        path.join(outDir, "index.html"),
        htmlPage({ ...r, manifestUrl, otaInstallUrl })
    );
    if (r.ipa) {
        await writeFile(path.join(outDir, "manifest.plist"), manifestPlist(r.ipa, r.tagName));
    }

    // Copy any static files from public/ if present.
    if (existsSync(publicDir)) {
        const { readdir } = await import("node:fs/promises");
        const items = await readdir(publicDir);
        for (const name of items) {
            await copyFile(path.join(publicDir, name), path.join(outDir, name));
        }
    }

    // Copy the deploy descriptor so `cd out && fyra push` works.
    const deployYaml = path.join(__dirname, ".deploy.yaml");
    if (existsSync(deployYaml)) {
        await copyFile(deployYaml, path.join(outDir, ".deploy.yaml"));
    }

    console.log(`wrote ${path.relative(process.cwd(), outDir)}/index.html · release ${r.tagName}`);
}

build().catch((err) => {
    console.error("build failed:", err.message);
    process.exit(1);
});
