# iOS Release Runbook — Ad-hoc Sideload IPA

This runbook covers the **end-to-end credential setup** that feeds
`.github/workflows/release-ios.yml`. Once secrets are populated, a `git tag v*`
push produces a signed ad-hoc IPA attached to the GitHub Release.

Most credential work is automated through the **App Store Connect MCP**
(`@seriousmonster/app-store-connect-mcp`, aka STOMP), driven from a Claude Code
session. See `docs/archive/PLAN.md` §C3 for the high-level workflow design.

---

## Prereqs (one-time, already done)

- ASC API key generated in App Store Connect → Users and Access → Keys
  (Admin role). Private key stored at:
  `/root/.appstoreconnect/AuthKey_75Z4CZ6SJ5.p8` (chmod 600, dir chmod 700)
- Key ID and Issuer ID exported as env vars consumed by the MCP server (set in
  `~/.claude.json` mcpServers entry).
- STOMP MCP added user-scoped:
  ```
  claude mcp add app-store-connect --scope user \
    -e APP_STORE_CONNECT_KEY_ID=75Z4CZ6SJ5 \
    -e APP_STORE_CONNECT_ISSUER_ID=69a6de81-788e-47e3-e053-5b8c7c11a4d1 \
    -e APP_STORE_CONNECT_P8_PATH=/root/.appstoreconnect/AuthKey_75Z4CZ6SJ5.p8 \
    -- npx -y @seriousmonster/app-store-connect-mcp
  ```
- `gh` CLI installed; authenticate once with `gh auth login`.
- Local secrets staging file: `/root/.appstoreconnect/secrets.env` (chmod 600)
  holds `IOS_KEYCHAIN_PASSWORD` and is the scratchpad for the values produced
  below before they get pushed to GitHub.

> **Constraint:** MCP tools are only available after Claude Code starts.
> If you add or change the MCP mid-session, restart Claude (`/exit` then relaunch)
> before driving the MCP from chat.

---

## Step 1 — Mint Apple Distribution certificate (MCP)

From a Claude Code session with the MCP loaded:

> Use `app-store-connect` MCP to:
> 1. List existing certificates of type `DISTRIBUTION` — if a current one exists and we have the private key, reuse it. Otherwise:
> 2. Generate a new private key + CSR locally, submit to ASC to create a new `DISTRIBUTION` cert.
> 3. Bundle the private key + cert into a `.p12` file with a strong password.
> 4. Save the `.p12` to `/root/.appstoreconnect/ConduitDist.p12`.
> 5. Write the `.p12` password to `IOS_CERTIFICATE_PASSWORD` in `/root/.appstoreconnect/secrets.env`.

Manual sanity check:
```bash
openssl pkcs12 -in /root/.appstoreconnect/ConduitDist.p12 -nokeys -passin pass:"$IOS_CERTIFICATE_PASSWORD" | openssl x509 -noout -subject -dates
```

---

## Step 2 — Fetch Team ID (MCP)

> Use `app-store-connect` MCP to fetch the team's `teamId` and write it to
> `IOS_TEAM_ID` in `/root/.appstoreconnect/secrets.env`.

---

## Step 3 — Register tester devices (MCP, repeat per tester)

For each new sideload tester, collect their device UDID (see
`docs/INSTALL-IOS.md` for AltStore/Sideloadly UDID retrieval), then:

> Use `app-store-connect` MCP to register device UDID `<UDID>` with name
> `<NAME>` and platform `IOS`.

Apple caps registered devices at **100/year per device class**. Track usage.

---

## Step 4 — Create or regenerate the ad-hoc provisioning profile (MCP)

> Use `app-store-connect` MCP to:
> 1. Look up the bundle ID `sh.nikhil.conduit` (create if missing).
> 2. List `IOS_APP_ADHOC` profiles named `Conduit AdHoc` — if one exists, regenerate it so it includes every currently-registered device; otherwise create it with all current devices and the Distribution cert from Step 1.
> 3. Download the profile (`.mobileprovision`) to `/root/.appstoreconnect/Conduit_AdHoc.mobileprovision`.

Profile regeneration is the operation you'll repeat most often — every time
Step 3 adds a new tester.

---

## Step 5 — Push secrets to GitHub

```bash
source /root/.appstoreconnect/secrets.env
REPO=nikhilsh/conduit

gh secret set IOS_CERTIFICATE_P12_BASE64 -R $REPO \
  < <(base64 -w0 /root/.appstoreconnect/ConduitDist.p12)
gh secret set IOS_PROVISIONING_PROFILE_BASE64 -R $REPO \
  < <(base64 -w0 /root/.appstoreconnect/Conduit_AdHoc.mobileprovision)
gh secret set IOS_CERTIFICATE_PASSWORD       -R $REPO --body "$IOS_CERTIFICATE_PASSWORD"
gh secret set IOS_KEYCHAIN_PASSWORD          -R $REPO --body "$IOS_KEYCHAIN_PASSWORD"
gh secret set IOS_TEAM_ID                    -R $REPO --body "$IOS_TEAM_ID"

gh secret list -R $REPO | grep IOS_
```

You should see all five `IOS_*` secrets present.

---

## Step 6 — Tag and release

```bash
cd /root/developer/projects/kitty-swe
git tag v0.0.1
git push origin v0.0.1
gh run watch -R $REPO   # follow the release-ios workflow
```

Outputs:
- A GitHub Release named `v0.0.1`
- `Conduit.ipa` attached as a release asset (ad-hoc signed, valid for the
  UDIDs in the profile until the profile expires — typically one year)

> **Blocker:** the workflow expects `apps/ios/` to exist (`project.yml`,
> `build-rust.sh`, `ExportOptions.plist`, `Conduit` scheme). If absent, the
> `xcodegen generate` step fails. Scaffold that before the first tag — see
> `docs/archive/PLAN.md` §B for the iOS app skeleton.

---

## Step 7 — Sideload onto a device

See `docs/INSTALL-IOS.md` for AltStore / Sideloadly / Apple Configurator
install paths. The UDID must already be in the profile from Step 4.

---

## Adding a new tester (the common case)

Steady-state flow once the cert exists and a profile is in place:

1. New tester sends their UDID.
2. MCP: register the device (Step 3).
3. MCP: regenerate the profile (Step 4).
4. `gh secret set IOS_PROVISIONING_PROFILE_BASE64 -R $REPO < <(base64 -w0 ...)`
5. Tag the next release. Tester sideloads the new IPA.

Steps 2 and 3 are a single MCP prompt away. The whole loop is under a minute.

---

## Rotation / cleanup

- **Cert expiry:** Apple Distribution certs are valid for 1 year. The MCP can
  list expiring certs; regenerate by re-running Step 1.
- **Device cap:** when nearing 100/year, MCP can list disabled devices and
  permanently remove ones no longer needed (resets at the membership year
  rollover).
- **Lost `.p12` private key:** the cert is unrecoverable. Revoke via MCP,
  re-run Step 1 from scratch, re-run Step 4 (profile rebinds to the new cert).
