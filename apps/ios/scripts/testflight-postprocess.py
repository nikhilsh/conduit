#!/usr/bin/env python3
"""Post-upload TestFlight automation (App Store Connect API).

Runs AFTER `xcodebuild -exportArchive ... destination=upload` has pushed the
build. Mirrors the high-value bits of litter's testflight-upload.sh, minus the
extras we don't need yet (no version-bump-commit, no external beta-review submit):

  1. Find our just-uploaded build (by app + CFBundleVersion == github.run_number).
  2. Optionally wait for Apple to finish PROCESSING it.
  3. Set the build's "What to Test" (per-build changelog).
  4. Assign the build to one or more beta groups (e.g. "Conduit Internal"),
     which is what actually makes it land for internal testers.

Auth uses the same ASC API key already staged for the upload. PyJWT is installed
by the workflow step before this runs. All inputs come from env:

  ASC_API_KEY_ID, ASC_API_ISSUER_ID, ASC_API_KEY_PATH   (the .p8 on disk)
  BUNDLE_ID            bundle identifier (sh.nikhil.conduit)
  BUILD_VERSION        CFBundleVersion of the upload (== github.run_number)
  BETA_GROUP_NAMES     comma-separated group names to assign (default "Conduit Internal")
  WHAT_TO_TEST         changelog text (optional; falls back to WHAT_TO_TEST_FILE)
  WHAT_TO_TEST_FILE    path to a file with the changelog (optional)
  WAIT_FOR_PROCESSING  "1"/"0" (default "1")
  POLL_TIMEOUT_SECONDS default 1800
  POLL_INTERVAL_SECONDS default 20
"""
import json
import os
import sys
import time
import urllib.request
import urllib.error

import jwt

BASE = "https://api.appstoreconnect.apple.com"


def env(name, default=None, required=False):
    v = os.environ.get(name, default)
    if required and not v:
        fail(f"missing required env {name}")
    return v


def log(msg):
    print(msg, flush=True)


def fail(msg):
    print(f"::error title=TestFlight post-process::{msg}", flush=True)
    sys.exit(1)


KEY_ID = env("ASC_API_KEY_ID", required=True)
ISSUER = env("ASC_API_ISSUER_ID", required=True)
KEY_PATH = env("ASC_API_KEY_PATH", required=True)
BUNDLE_ID = env("BUNDLE_ID", required=True)
BUILD_VERSION = str(env("BUILD_VERSION", required=True)).strip()
GROUP_NAMES = [g.strip() for g in env("BETA_GROUP_NAMES", "Conduit Internal").split(",") if g.strip()]
WAIT = env("WAIT_FOR_PROCESSING", "1") == "1"
TIMEOUT = int(env("POLL_TIMEOUT_SECONDS", "1800"))
INTERVAL = int(env("POLL_INTERVAL_SECONDS", "20"))

what = env("WHAT_TO_TEST", "")
if not what:
    f = env("WHAT_TO_TEST_FILE", "")
    if f and os.path.exists(f):
        with open(f) as fh:
            what = fh.read()
WHAT_TO_TEST = what.strip()


def token():
    now = int(time.time())
    return jwt.encode(
        {"iss": ISSUER, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"},
        open(KEY_PATH).read(), algorithm="ES256", headers={"kid": KEY_ID, "typ": "JWT"})


def req(method, path, body=None):
    r = urllib.request.Request(BASE + path, method=method,
                               data=json.dumps(body).encode() if body else None)
    r.add_header("Authorization", "Bearer " + token())
    r.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(r, timeout=30) as resp:
            txt = resp.read().decode()
            return resp.status, (json.loads(txt) if txt else {})
    except urllib.error.HTTPError as e:
        try:
            return e.code, json.loads(e.read().decode() or "{}")
        except Exception:
            return e.code, {}


def err(res):
    es = res.get("errors", [{}])
    return es[0].get("detail") or es[0].get("title") or json.dumps(res)[:300]


def resolve_app_id():
    st, res = req("GET", f"/v1/apps?filter[bundleId]={BUNDLE_ID}&limit=1")
    data = res.get("data", [])
    if st != 200 or not data:
        fail(f"could not resolve app for bundle {BUNDLE_ID}: {err(res)}")
    return data[0]["id"]


def find_build(app_id):
    """Find the build whose CFBundleVersion == BUILD_VERSION (most recent)."""
    st, res = req("GET", f"/v1/builds?filter[app]={app_id}&filter[version]={BUILD_VERSION}"
                         f"&sort=-uploadedDate&limit=5")
    for b in res.get("data", []):
        if str(b["attributes"].get("version")) == BUILD_VERSION:
            return b
    return None


def main():
    app_id = resolve_app_id()
    log(f"==> app {app_id} ({BUNDLE_ID}), looking for build {BUILD_VERSION}")

    deadline = time.time() + TIMEOUT
    build = None
    while time.time() < deadline:
        build = find_build(app_id)
        if build:
            state = build["attributes"].get("processingState")
            log(f"    build {build['id']} state={state}")
            if not WAIT or state in ("VALID", "FAILED", "INVALID"):
                break
        else:
            log("    build not visible yet (ASC ingest lag)...")
        time.sleep(INTERVAL)

    if not build:
        fail(f"build {BUILD_VERSION} never appeared within {TIMEOUT}s "
             f"(upload may still be ingesting — re-run post-process or assign in ASC).")

    bid = build["id"]
    state = build["attributes"].get("processingState")
    if state in ("FAILED", "INVALID"):
        fail(f"build {bid} processing {state} — cannot distribute.")

    # ---- What to Test (per-build changelog) ----
    if WHAT_TO_TEST:
        st, locs = req("GET", f"/v1/builds/{bid}/betaBuildLocalizations")
        existing = next((l for l in locs.get("data", [])
                         if l["attributes"].get("locale") == "en-US"), None)
        if existing:
            st, res = req("PATCH", f"/v1/betaBuildLocalizations/{existing['id']}",
                          {"data": {"type": "betaBuildLocalizations", "id": existing["id"],
                                    "attributes": {"whatsNew": WHAT_TO_TEST}}})
        else:
            st, res = req("POST", "/v1/betaBuildLocalizations",
                          {"data": {"type": "betaBuildLocalizations",
                                    "attributes": {"locale": "en-US", "whatsNew": WHAT_TO_TEST},
                                    "relationships": {"build": {"data": {"type": "builds", "id": bid}}}}})
        log("==> What to Test " + ("set" if st in (200, 201) else "FAILED: " + err(res)))
    else:
        log("==> no What to Test provided; skipping")

    # ---- Beta group assignment (requires a processed build) ----
    if state != "VALID":
        log(f"::warning title=TestFlight::build still {state}; skipping group assignment. "
            f"Re-run with wait_for_processing, or assign in ASC once processed.")
        return

    st, groups = req("GET", f"/v1/apps/{app_id}/betaGroups?limit=200")
    by_name = {g["attributes"]["name"]: g["id"] for g in groups.get("data", [])}
    for name in GROUP_NAMES:
        gid = by_name.get(name)
        if not gid:
            log(f"::warning title=TestFlight::beta group '{name}' not found; skipping.")
            continue
        st, res = req("POST", f"/v1/builds/{bid}/relationships/betaGroups",
                      {"data": [{"type": "betaGroups", "id": gid}]})
        log(f"==> assign to '{name}': " + ("OK" if st in (200, 201, 204) else "FAILED: " + err(res)))

    log(f"::notice title=TestFlight::build {BUILD_VERSION} ({bid}) distributed to: {', '.join(GROUP_NAMES)}")


if __name__ == "__main__":
    main()
