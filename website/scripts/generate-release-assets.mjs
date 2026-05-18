import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const dataDir = path.join(root, "data");
const publicDir = path.join(root, "public");

const repo = process.env.GITHUB_REPO || "nikhilsh/swe-kitty";
const siteOrigin = process.env.SITE_ORIGIN || "https://swekitty.kaopeh.com";

const response = await fetch(`https://api.github.com/repos/${repo}/releases/latest`, {
  headers: {
    "User-Agent": "swe-kitty-website-build",
    Accept: "application/vnd.github+json",
  },
});

if (!response.ok) {
  throw new Error(`failed to fetch latest release: ${response.status} ${response.statusText}`);
}

const release = await response.json();
const assets = Array.isArray(release.assets) ? release.assets : [];

const ipa = assets.find((asset) => asset.name === "SweKitty.ipa");
const apk = assets.find((asset) => asset.name.endsWith(".apk"));

const releaseData = {
  repo,
  siteOrigin,
  releaseName: release.name,
  tagName: release.tag_name,
  releaseUrl: release.html_url,
  publishedAt: release.published_at,
  ipa: ipa
    ? {
        name: ipa.name,
        url: ipa.browser_download_url,
      }
    : null,
  apk: apk
    ? {
        name: apk.name,
        url: apk.browser_download_url,
      }
    : null,
};

await mkdir(dataDir, { recursive: true });
await mkdir(publicDir, { recursive: true });
await writeFile(path.join(dataDir, "release.json"), `${JSON.stringify(releaseData, null, 2)}\n`);

if (ipa) {
  const manifest = `<?xml version="1.0" encoding="UTF-8"?>
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
        <string>sh.nikhil.swekitty</string>
        <key>bundle-version</key>
        <string>${release.tag_name}</string>
        <key>kind</key>
        <string>software</string>
        <key>title</key>
        <string>SweKitty</string>
      </dict>
    </dict>
  </array>
</dict>
</plist>
`;
  await writeFile(path.join(publicDir, "manifest.plist"), manifest);
}
