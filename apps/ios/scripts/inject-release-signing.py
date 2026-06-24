#!/usr/bin/env python3
"""Inject manual code-signing into the release targets of apps/ios/project.yml.

Run by the release workflows (release-ios.yml / release-testflight.yml) after
the signing assets are staged but BEFORE `xcodegen generate`. The host app,
the Live Activity widget extension, and the notification service extension each
have distinct bundle ids and need their own provisioning profile. Profile names
are ${PROFILE_NAME} / ${WIDGET_PROFILE_NAME} / ${NOTIF_PROFILE_NAME} (exported
to the job env by the "Install provisioning profile" step); xcodebuild resolves
these build-setting references from its environment at build time.
"""
from pathlib import Path

path = Path("project.yml")
text = path.read_text()

# --- host app target (unchanged behaviour: same literals as before) ---
app_marker = "        ENABLE_MODULE_VERIFIER: NO\n"
app_replacement = (
    "        ENABLE_MODULE_VERIFIER: NO\n"
    "        CODE_SIGN_STYLE: Manual\n"
    "        CODE_SIGN_IDENTITY: Apple Distribution\n"
    "        DEVELOPMENT_TEAM: ${TEAM_ID}\n"
    "        PROVISIONING_PROFILE_SPECIFIER: ${PROFILE_NAME}\n"
)
if app_marker not in text:
    raise SystemExit("app signing marker (ENABLE_MODULE_VERIFIER) not found in project.yml")
text = text.replace(app_marker, app_replacement, 1)

# --- Live Activity widget extension target ---
widget_marker = (
    "        PRODUCT_BUNDLE_IDENTIFIER: sh.nikhil.conduit.widgets\n"
    '        TARGETED_DEVICE_FAMILY: "1,2"\n'
    "        SUPPORTS_MACCATALYST: NO\n"
    "        GENERATE_INFOPLIST_FILE: NO\n"
    "        SKIP_INSTALL: NO\n"
    "        # Extension ships with the host .app and must not require its\n"
    "        # own signing identity for sim/CI builds.\n"
    "        CODE_SIGN_STYLE: Automatic\n"
    "        CODE_SIGNING_REQUIRED: NO\n"
    "        CODE_SIGNING_ALLOWED: NO\n"
)
widget_replacement = (
    "        PRODUCT_BUNDLE_IDENTIFIER: sh.nikhil.conduit.widgets\n"
    '        TARGETED_DEVICE_FAMILY: "1,2"\n'
    "        SUPPORTS_MACCATALYST: NO\n"
    "        GENERATE_INFOPLIST_FILE: NO\n"
    "        SKIP_INSTALL: NO\n"
    "        # Release: manual signing with the widget's own provisioning profile.\n"
    "        CODE_SIGN_STYLE: Manual\n"
    "        CODE_SIGN_IDENTITY: Apple Distribution\n"
    "        DEVELOPMENT_TEAM: ${TEAM_ID}\n"
    "        PROVISIONING_PROFILE_SPECIFIER: ${WIDGET_PROFILE_NAME}\n"
    "        CODE_SIGNING_REQUIRED: YES\n"
    "        CODE_SIGNING_ALLOWED: YES\n"
)
if widget_marker not in text:
    raise SystemExit("widget signing marker not found in project.yml")
text = text.replace(widget_marker, widget_replacement, 1)

# --- notification service extension target ---
notif_marker = (
    "        PRODUCT_BUNDLE_IDENTIFIER: sh.nikhil.conduit.notificationservice\n"
    '        TARGETED_DEVICE_FAMILY: "1,2"\n'
    "        SUPPORTS_MACCATALYST: NO\n"
    "        GENERATE_INFOPLIST_FILE: NO\n"
    "        CODE_SIGN_STYLE: Automatic\n"
    "        CODE_SIGNING_REQUIRED: NO\n"
    "        CODE_SIGNING_ALLOWED: NO\n"
)
notif_replacement = (
    "        PRODUCT_BUNDLE_IDENTIFIER: sh.nikhil.conduit.notificationservice\n"
    '        TARGETED_DEVICE_FAMILY: "1,2"\n'
    "        SUPPORTS_MACCATALYST: NO\n"
    "        GENERATE_INFOPLIST_FILE: NO\n"
    "        # Release: manual signing with the notification service's own provisioning profile.\n"
    "        CODE_SIGN_STYLE: Manual\n"
    "        CODE_SIGN_IDENTITY: Apple Distribution\n"
    "        DEVELOPMENT_TEAM: ${TEAM_ID}\n"
    "        PROVISIONING_PROFILE_SPECIFIER: ${NOTIF_PROFILE_NAME}\n"
    "        CODE_SIGNING_REQUIRED: YES\n"
    "        CODE_SIGNING_ALLOWED: YES\n"
)
if notif_marker not in text:
    raise SystemExit("notification service signing marker not found in project.yml")
text = text.replace(notif_marker, notif_replacement, 1)

path.write_text(text)
print("injected manual signing for app + widget + notification service targets")
