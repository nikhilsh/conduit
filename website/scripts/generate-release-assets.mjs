import { mkdir, writeFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const root = path.resolve(__dirname, "..");
const dataDir = path.join(root, "data");
const publicDir = path.join(root, "public");

const repo = process.env.GITHUB_REPO || "nikhilsh/swe-kitty";
const siteOrigin = process.env.SITE_ORIGIN || "https://swekitty.kaopeh.com";

const response = await fetch(`https://api.github.com/repos/${repo}/releases?per_page=10`, {
  headers: {
    "User-Agent": "swe-kitty-website-build",
    Accept: "application/vnd.github+json",
  },
});

if (!response.ok) {
  throw new Error(`failed to fetch releases: ${response.status} ${response.statusText}`);
}

const releases = await response.json();
if (!Array.isArray(releases) || releases.length === 0) {
  throw new Error("no releases returned from GitHub");
}

const isPublished = (item) => !item.draft && !item.prerelease;
const assetsOf = (item) => (Array.isArray(item.assets) ? item.assets : []);
const hasIpa = (item) => assetsOf(item).some((asset) => asset.name === "SweKitty.ipa");

const release =
  releases.find((item) => isPublished(item) && hasIpa(item)) ??
  releases.find((item) => !item.draft && hasIpa(item)) ??
  releases.find((item) => isPublished(item)) ??
  releases.find((item) => !item.draft) ??
  releases[0];

const assets = assetsOf(release);

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
