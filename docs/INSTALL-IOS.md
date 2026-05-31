# Installing Conduit on iOS (sideload)

Conduit is distributed as an **ad-hoc signed IPA** on each GitHub Release.
No TestFlight, no App Store. You install it like any other sideloaded
build.

## Prerequisites

- A device whose **UDID is in the ad-hoc provisioning profile** bundled
  into the build. Ad-hoc profiles hold ≤ 100 device UDIDs; the project
  owner adds yours via App Store Connect, then publishes a new tag.
- iOS 17 or later (`apps/ios/project.yml` sets `deploymentTarget: iOS 17.0`).
- One of: **AltStore**, **Sideloadly**, or **Apple Configurator**.

If you don't see your device in the latest release notes, ping the
project owner with your UDID. Get it from
`Settings → General → About → "Identifier"` (long-press to copy).

## Get the IPA

From the latest release at
<https://github.com/nikhilsh/conduit/releases>:

```
Conduit-vX.Y.Z.ipa
```

## Install — AltStore (recommended)

1. Install AltServer on your Mac/PC; install AltStore on the iPhone via
   AltServer once.
2. AirDrop / iCloud Drive the IPA to the iPhone.
3. Open Files → tap the IPA → "Share" → "Copy to AltStore".
4. AltStore installs and re-signs with your Apple ID; the app appears on
   the home screen.

Ad-hoc-signed apps don't need to be re-signed every 7 days — AltStore
handles refresh automatically while it's connected to AltServer.

## Install — Sideloadly

1. Install Sideloadly on Mac/PC.
2. Plug the iPhone in, trust the computer.
3. Drag the IPA onto Sideloadly, enter your Apple ID, click *Start*.

## Install — Apple Configurator

1. Plug the iPhone in, open Apple Configurator on a Mac.
2. Drag the IPA onto the device tile.

## First launch

- Open *Settings → General → VPN & Device Management* and trust the
  signing identity. (Ad-hoc profiles are pre-trusted on devices whose
  UDID is in the profile; this step is for Apple-ID-signed re-signs.)
- Launch Conduit → the **Settings sheet** opens.
- Either type the broker endpoint + bearer token manually, or tap
  **Scan pairing QR** and point the camera at the QR printed when you
  ran `conduit-broker up`.

## Updating

Pull the new IPA from a fresh release and repeat the install step. State
(endpoint + token in Keychain, scrollback in memory) is preserved across
upgrades because the bundle ID `sh.nikhil.conduit` is stable.

## Troubleshooting

- **"Unable to install"** — your UDID isn't in the profile. Ask for a
  rebuild with your UDID added.
- **App opens then immediately closes** — usually a Keychain entitlement
  mismatch when you've switched between AltStore-signed and ad-hoc-signed
  builds. Delete the app and reinstall.
- **Camera permission denied for QR** — *Settings → Conduit → Camera*.

See also: `docs/RELEASE-IOS.md` for the maintainer-side release flow.
