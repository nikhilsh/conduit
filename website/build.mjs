#!/usr/bin/env node
// build.mjs — static-site generator for Conduit.
//
// Renders the Conduit marketing site from `index.template.html` (the design
// handoff site) + the latest GitHub release. The page reads `version.json`
// at runtime and falls back to an inline `#release-data` block, both of which
// we generate here from the release's IPA/APK assets.
//
// Output: website/out/{index.html, version.json, ios/manifest.plist,
//                      assets/*, .deploy.yaml}.
// `fyra push` from website/out/ ships it.

import { mkdir, writeFile, copyFile, readFile, readdir, rm } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { webcrypto as wc } from "node:crypto";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const outDir = path.join(__dirname, "out");
const assetsSrc = path.join(__dirname, "public", "assets");
const templatePath = path.join(__dirname, "index.template.html");
const privacyPath = path.join(__dirname, "privacy.template.html");
const deployYaml = path.join(__dirname, ".deploy.yaml");

const repo = process.env.GITHUB_REPO || "nikhilsh/conduit";
const siteOrigin = process.env.SITE_ORIGIN || "https://conduit.kaopeh.com";

const headers = {
    "User-Agent": "conduit-website-build",
    Accept: "application/vnd.github+json",
};
const token = process.env.GITHUB_TOKEN || process.env.GH_TOKEN;
if (token) headers.Authorization = `Bearer ${token}`;

async function fetchLatestRelease() {
    // Bound the build on a hung api.github.com instead of stalling forever.
    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), 15000);
    let res;
    try {
        res = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=20`, {
            headers,
            signal: ctrl.signal,
        });
    } finally {
        clearTimeout(timer);
    }
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

const mb = (bytes) => (bytes ? (bytes / 1048576).toFixed(1) + " MB" : "");

const b64 = (u8) => Buffer.from(u8).toString("base64");

async function buildGatedPage(plaintext, password) {
    const enc = new TextEncoder();
    const salt = wc.getRandomValues(new Uint8Array(16));
    const iv = wc.getRandomValues(new Uint8Array(12));
    const baseKey = await wc.subtle.importKey("raw", enc.encode(password), { name: "PBKDF2" }, false, ["deriveKey"]);
    const key = await wc.subtle.deriveKey(
        { name: "PBKDF2", salt, iterations: 200000, hash: "SHA-256" },
        baseKey,
        { name: "AES-GCM", length: 256 },
        false,
        ["encrypt"],
    );
    const ctBuf = await wc.subtle.encrypt({ name: "AES-GCM", iv }, key, enc.encode(plaintext));

    const SALT = b64(salt);
    const IV = b64(iv);
    const CT = b64(new Uint8Array(ctBuf));

    return `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>conduit · broker field guide</title>
<style>
  *, *::before, *::after { box-sizing: border-box; margin: 0; padding: 0; }
  html, body { height: 100%; }
  body {
    background: #0d0d0d;
    color: #c9d1d9;
    font-family: 'SF Mono', 'Fira Code', 'Cascadia Code', monospace;
    display: flex;
    align-items: center;
    justify-content: center;
    min-height: 100vh;
  }
  .card {
    width: 100%;
    max-width: 420px;
    padding: 2.5rem 2rem;
    background: #161b22;
    border: 1px solid #30363d;
    border-radius: 8px;
  }
  h1 {
    font-size: 1rem;
    font-weight: 600;
    color: #e6edf3;
    letter-spacing: 0.02em;
    margin-bottom: 0.4rem;
  }
  .sub {
    font-size: 0.75rem;
    color: #6e7681;
    margin-bottom: 2rem;
  }
  label {
    display: block;
    font-size: 0.72rem;
    color: #8b949e;
    margin-bottom: 0.5rem;
    text-transform: uppercase;
    letter-spacing: 0.08em;
  }
  input[type="password"] {
    width: 100%;
    padding: 0.6rem 0.8rem;
    background: #0d1117;
    border: 1px solid #30363d;
    border-radius: 6px;
    color: #e6edf3;
    font-family: inherit;
    font-size: 0.9rem;
    outline: none;
    transition: border-color 0.15s;
    margin-bottom: 1rem;
  }
  input[type="password"]:focus { border-color: #58a6ff; }
  input[type="password"].shake {
    animation: shake 0.35s ease;
    border-color: #f85149;
  }
  @keyframes shake {
    0%, 100% { transform: translateX(0); }
    20%       { transform: translateX(-6px); }
    40%       { transform: translateX(6px); }
    60%       { transform: translateX(-4px); }
    80%       { transform: translateX(4px); }
  }
  button {
    width: 100%;
    padding: 0.6rem 1rem;
    background: #238636;
    border: 1px solid #2ea043;
    border-radius: 6px;
    color: #fff;
    font-family: inherit;
    font-size: 0.875rem;
    font-weight: 600;
    cursor: pointer;
    transition: background 0.15s;
  }
  button:hover { background: #2ea043; }
  button:disabled { opacity: 0.5; cursor: default; }
  .err {
    margin-top: 0.9rem;
    font-size: 0.78rem;
    color: #f85149;
    min-height: 1.1em;
    text-align: center;
  }
</style>
</head>
<body>
<div class="card">
  <h1>conduit · broker field guide</h1>
  <p class="sub">internal documentation — access restricted</p>
  <label for="pw">password</label>
  <input type="password" id="pw" autocomplete="current-password" autofocus>
  <button id="btn">Unlock</button>
  <p class="err" id="err"></p>
</div>
<script>
const SALT = "${SALT}";
const IV   = "${IV}";
const CT   = "${CT}";

const b64d = (s) => Uint8Array.from(atob(s), c => c.charCodeAt(0));

async function unlock(pw) {
  const enc = new TextEncoder();
  const baseKey = await crypto.subtle.importKey("raw", enc.encode(pw), { name: "PBKDF2" }, false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey(
    { name: "PBKDF2", salt: b64d(SALT), iterations: 200000, hash: "SHA-256" },
    baseKey,
    { name: "AES-GCM", length: 256 },
    false,
    ["decrypt"],
  );
  const pt = await crypto.subtle.decrypt({ name: "AES-GCM", iv: b64d(IV) }, key, b64d(CT));
  const html = new TextDecoder().decode(pt);
  document.open(); document.write(html); document.close();
}

const btn = document.getElementById("btn");
const pw  = document.getElementById("pw");
const err = document.getElementById("err");

async function attempt() {
  const val = pw.value;
  if (!val) return;
  btn.disabled = true;
  err.textContent = "";
  try {
    await unlock(val);
  } catch (_) {
    pw.classList.remove("shake");
    void pw.offsetWidth; // reflow to restart animation
    pw.classList.add("shake");
    err.textContent = "incorrect password";
    pw.value = "";
    pw.focus();
  } finally {
    btn.disabled = false;
  }
}

btn.addEventListener("click", attempt);
pw.addEventListener("keydown", (e) => { if (e.key === "Enter") attempt(); });
pw.addEventListener("animationend", () => pw.classList.remove("shake"));
</script>
</body>
</html>`;
}

async function build() {
    const r = await fetchLatestRelease();
    const version = (r.tagName || "").replace(/^v/, "");
    const updated = (r.publishedAt || "").slice(0, 10);
    const manifestUrl = `itms-services://?action=download-manifest&url=${siteOrigin}/ios/manifest.plist`;

    const releaseData = {
        version,
        channel: "alpha",
        updated,
        // Full ISO-8601 build timestamp (the release's publish time). The page
        // renders it in the visitor's locale + timezone via `toLocaleString`.
        builtAt: r.publishedAt || "",
        ios: {
            manifestUrl: r.ipa ? manifestUrl : "",
            // Stable public TestFlight join link — the recommended iOS path.
            testflightUrl: "https://testflight.apple.com/join/KkcgMdcm",
            minOS: "iOS 16+",
            size: mb(r.ipa?.size),
        },
        android: {
            apkUrl: r.apk ? r.apk.browser_download_url : "",
            minOS: "Android 10+",
            size: mb(r.apk?.size),
        },
    };
    const json = JSON.stringify(releaseData, null, 2);
    // Escape `<` so a release field can never break out of the inline
    // <script type="application/json"> block (e.g. a stray `</script`).
    const jsonForHtml = json.replace(/</g, "\\u003c");

    // Render the page: inject the real release data into the inline
    // `#release-data` fallback so the page is correct even before the
    // runtime `version.json` fetch resolves (and for no-JS clients).
    let html = await readFile(templatePath, "utf8");
    html = html.replace(
        /(<script type="application\/json" id="release-data">)[\s\S]*?(<\/script>)/,
        `$1\n${jsonForHtml}\n$2`,
    );
    // Bake the real version into the eyebrow badge so it's correct in the
    // static HTML (no-JS / first paint), not just after the runtime
    // version.json fetch updates `[data-version]`.
    if (version) {
        html = html.replace(
            /(<span data-version>)[^<]*(<\/span>)/g,
            `$1v${version}$2`,
        );
    }

    // Clean first so each build is hermetic — otherwise stale artifacts from a
    // previous toolchain (e.g. an old Next.js export) survive and get shipped.
    await rm(outDir, { recursive: true, force: true });
    await mkdir(outDir, { recursive: true });
    await mkdir(path.join(outDir, "ios"), { recursive: true });
    await mkdir(path.join(outDir, "assets"), { recursive: true });

    await writeFile(path.join(outDir, "index.html"), html);
    await writeFile(path.join(outDir, "version.json"), json + "\n");
    if (r.ipa) {
        await writeFile(path.join(outDir, "ios", "manifest.plist"), manifestPlist(r.ipa, r.tagName));
    }
    for (const name of await readdir(assetsSrc)) {
        await copyFile(path.join(assetsSrc, name), path.join(outDir, "assets", name));
    }
    // Privacy policy is a static standalone page (no release data injected) —
    // emitted at /privacy.html, which is the URL given to App Store Connect.
    await writeFile(path.join(outDir, "privacy.html"), await readFile(privacyPath, "utf8"));
    if (existsSync(deployYaml)) {
        await copyFile(deployYaml, path.join(outDir, ".deploy.yaml"));
    }

    const brokerSrc = path.join(__dirname, "broker.template.html");
    if (existsSync(brokerSrc)) {
        const plaintext = await readFile(brokerSrc, "utf8");
        const password = process.env.BROKER_PAGE_PASSWORD || "nikhil123";
        const gate = await buildGatedPage(plaintext, password);
        await mkdir(path.join(outDir, "broker"), { recursive: true });
        await writeFile(path.join(outDir, "broker", "index.html"), gate); // serves at /broker
        await writeFile(path.join(outDir, "broker.html"), gate);          // serves at /broker.html
        console.log("wrote out/broker/index.html (password-gated)");
    }

    console.log(
        `wrote out/index.html · release ${r.tagName} · iOS ${releaseData.ios.size || "—"} · APK ${releaseData.android.size || "—"}`,
    );
}

build().catch((e) => {
    console.error(e);
    process.exit(1);
});
