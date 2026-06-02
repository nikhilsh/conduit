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

import { mkdir, writeFile, copyFile, readFile, readdir } from "node:fs/promises";
import { existsSync } from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";

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

const mb = (bytes) => (bytes ? (bytes / 1048576).toFixed(1) + " MB" : "");

async function build() {
    const r = await fetchLatestRelease();
    const version = (r.tagName || "").replace(/^v/, "");
    const updated = (r.publishedAt || "").slice(0, 10);
    const manifestUrl = `itms-services://?action=download-manifest&url=${siteOrigin}/ios/manifest.plist`;

    const releaseData = {
        version,
        channel: "beta",
        updated,
        ios: {
            manifestUrl: r.ipa ? manifestUrl : "",
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

    // Render the page: inject the real release data into the inline
    // `#release-data` fallback so the page is correct even before the
    // runtime `version.json` fetch resolves (and for no-JS clients).
    let html = await readFile(templatePath, "utf8");
    html = html.replace(
        /(<script type="application\/json" id="release-data">)[\s\S]*?(<\/script>)/,
        `$1\n${json}\n$2`,
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

    console.log(
        `wrote out/index.html · release ${r.tagName} · iOS ${releaseData.ios.size || "—"} · APK ${releaseData.android.size || "—"}`,
    );
}

build().catch((e) => {
    console.error(e);
    process.exit(1);
});
