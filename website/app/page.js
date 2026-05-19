import release from "../data/release.json";

const releaseUrl = release.releaseUrl || "https://github.com/nikhilsh/swe-kitty/releases/latest";
const docsUrl = "https://github.com/nikhilsh/swe-kitty/tree/main/docs";
const repoUrl = "https://github.com/nikhilsh/swe-kitty";
const manifestUrl = `${release.siteOrigin || "https://swekitty.kaopeh.com"}/manifest.plist`;
const otaInstallUrl = `itms-services://?action=download-manifest&url=${encodeURIComponent(manifestUrl)}`;
const publishedUtcLabel = release.publishedAt
  ? `${new Date(release.publishedAt).toLocaleString("en-US", {
      dateStyle: "medium",
      timeStyle: "short",
      timeZone: "UTC",
    })} UTC`
  : null;
const publishedLocalLabel = release.publishedAt
  ? `${new Date(release.publishedAt).toLocaleString("en-US", {
      year: "numeric",
      month: "short",
      day: "numeric",
      hour: "numeric",
      minute: "2-digit",
      timeZoneName: "short",
    })} Local`
  : null;

const featureCards = [
  {
    title: "Drive agents from your phone",
    body:
      "Open a project and keep terminal, agent chat, and browser preview side by side instead of bouncing between desktop tools.",
  },
  {
    title: "Real harness, not a toy shell",
    body:
      "The Go harness manages PTYs, worktrees, adapters, and live session recovery so mobile control still maps to an actual development loop.",
  },
  {
    title: "Shared core across iOS and Android",
    body:
      "Rust handles the protocol and session client so both mobile apps ship the same transport and state behavior.",
  },
];

const platformCards = [
  {
    name: "iOS",
    detail: "Ad hoc IPA with OTA install path from the site itself.",
  },
  {
    name: "Android",
    detail: "Signed APK release asset when Android signing is configured.",
  },
  {
    name: "Self-host",
    detail: "Harness, adapters, and protocol docs are all in the repo.",
  },
];

export default function HomePage() {
  return (
    <main className="page">
      <div className="masthead">
        <span className="masthead-tag">swe-kitty</span>
        <span className="masthead-tag mute">mobile harness for serious agent sessions</span>
      </div>

      <section className="downloads downloads-prominent">
        <div className="section-head">
          <p className="eyebrow">Builds</p>
          <h2>Install the current release directly.</h2>
        </div>
        <div className="download-card">
          <p>Each release carries the current mobile builds and harness binaries.</p>
          {release.tagName ? (
            <p className="release-meta">
              Current release: <strong>{release.tagName}</strong>
              {publishedUtcLabel || publishedLocalLabel
                ? ` · published ${publishedUtcLabel ?? ""}${publishedUtcLabel && publishedLocalLabel ? " · " : ""}${publishedLocalLabel ?? ""}`
                : ""}
            </p>
          ) : null}
          <div className="actions">
            {release.ipa ? <a className="button primary" href={otaInstallUrl}>Install on iPhone or iPad</a> : null}
            {release.ipa ? <a className="button secondary" href={release.ipa.url}>Download IPA</a> : null}
            {release.apk ? <a className="button tertiary" href={release.apk.url}>Download APK</a> : null}
            {!release.apk ? <a className="button tertiary" href={releaseUrl}>Open latest release</a> : null}
            <a className="button tertiary" href={docsUrl}>
              Read docs
            </a>
          </div>
          <div className="build-grid">
            <article className="build-card">
              <span className="build-label">iOS</span>
              <strong>{release.ipa ? "ready" : "missing"}</strong>
              <p>OTA install plus direct IPA download from the latest signed release.</p>
            </article>
            <article className="build-card">
              <span className="build-label">Android</span>
              <strong>{release.apk ? "ready" : "not in latest release"}</strong>
              <p>
                {release.apk
                  ? "Direct APK download is available."
                  : "The website is ready to expose the APK as soon as the signed Android release asset ships."}
              </p>
            </article>
          </div>
          <p className="download-note">
            iOS OTA install works from iPhone or iPad using the manifest hosted on this site. If install fails, use the direct IPA link or open the release page.
          </p>
        </div>
      </section>

      <section className="hero">
        <div className="hero-copy">
          <p className="eyebrow">Command surface for mobile coding</p>
          <h1>Run Claude Code and Codex from your phone without reducing them to chat bubbles.</h1>
          <p className="lede">
            swe-kitty pairs a Go harness, a Rust session core, and native mobile clients so you can
            drive serious coding sessions from iOS or Android.
          </p>
          <div className="actions">
            <a className="button primary" href={releaseUrl}>
              Get the latest build
            </a>
            <a className="button secondary" href={repoUrl}>
              View the repository
            </a>
          </div>
        </div>
        <div className="hero-panel">
          <div className="signal-grid">
            <div className="signal-block">
              <span className="signal-label">transport</span>
              <strong>websocket</strong>
            </div>
            <div className="signal-block">
              <span className="signal-label">core</span>
              <strong>rust + uniffi</strong>
            </div>
            <div className="signal-block">
              <span className="signal-label">harness</span>
              <strong>go + pty</strong>
            </div>
            <div className="signal-block accent-block">
              <span className="signal-label">live mode</span>
              <strong>multi-agent</strong>
            </div>
          </div>
          <div className="terminal-body">
            <p className="prompt">session[alpha] :: attach</p>
            <p className="muted">terminal stream stable</p>
            <p className="muted">browser preview synchronized</p>
            <p className="accent">assistant swap -&gt; codex</p>
            <p className="muted">handoff + memory rendering active</p>
          </div>
        </div>
      </section>

      <section className="platforms">
        {platformCards.map((platform) => (
          <article className="platform-card" key={platform.name}>
            <h2>{platform.name}</h2>
            <p>{platform.detail}</p>
          </article>
        ))}
      </section>

      <section className="features">
        <div className="section-head">
          <p className="eyebrow">What it is</p>
          <h2>The stack is opinionated end to end.</h2>
        </div>
        <div className="feature-grid">
          {featureCards.map((card) => (
            <article className="feature-card" key={card.title}>
              <h3>{card.title}</h3>
              <p>{card.body}</p>
            </article>
          ))}
        </div>
      </section>

      <section className="footer-strip">
        <p>swe-kitty is open source and contract-driven: protocol, adapter, memory, and lifecycle docs live in the repo.</p>
      </section>
    </main>
  );
}
