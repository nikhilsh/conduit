// Per-install auth + rate limiting backed by a KV namespace.
//
// Auth model (matches WS-P.1's "minted on first use" credential): the relay
// trusts any well-formed install_id+install_secret pair, but pins a hash of
// the secret to the id on first use so a later request can't squat an
// existing id with a different secret. Zero account management; the broker
// generates the pair and stores it under ~/.conduit/.

import { base64urlEncode } from "./jwt";

export interface RateLimitEnv {
  RATE_LIMIT: KVNamespace;
}

const ID_RE = /^[0-9a-f]{16,64}$/;
const DAILY_LIMIT = 300;
// 25h so a day's window survives a late-night clock-edge without resetting
// the counter early; KV TTL minimum is 60s and this is comfortably above.
const COUNTER_TTL_SECONDS = 90000;

export type AuthResult =
  | { ok: true }
  | { ok: false; status: 400 | 401 | 429; error: string };

export function isWellFormedId(id: unknown): id is string {
  return typeof id === "string" && ID_RE.test(id);
}

export function isWellFormedSecret(secret: unknown): secret is string {
  return typeof secret === "string" && secret.length >= 32;
}

async function hashSecret(secret: string): Promise<string> {
  const digest = await crypto.subtle.digest("SHA-256", new TextEncoder().encode(secret));
  return base64urlEncode(digest);
}

function todayUTC(now: Date): string {
  return now.toISOString().slice(0, 10); // YYYY-MM-DD
}

// Validate the credential pair and consume one unit of the daily quota.
// On success the install's daily counter has been incremented. Returns a
// terse error otherwise — never echoes the secret.
export async function authenticateAndRateLimit(
  env: RateLimitEnv,
  installId: string,
  installSecret: string,
  now: Date = new Date(),
): Promise<AuthResult> {
  if (!isWellFormedId(installId)) {
    return { ok: false, status: 400, error: "malformed install_id" };
  }
  if (!isWellFormedSecret(installSecret)) {
    return { ok: false, status: 400, error: "malformed install_secret" };
  }

  // Pin-on-first-use: bind the secret hash to the id, reject mismatches.
  const authKey = `auth:${installId}`;
  const pinned = await env.RATE_LIMIT.get(authKey);
  const provided = await hashSecret(installSecret);
  if (pinned === null) {
    // First use — pin it (no TTL). A benign race where two first-uses
    // arrive together is harmless: both write the same hash for the same
    // secret, and a mismatched secret would lose the race only to be
    // rejected on its next request.
    await env.RATE_LIMIT.put(authKey, provided);
  } else if (pinned !== provided) {
    return { ok: false, status: 401, error: "install_secret mismatch" };
  }

  // Daily rate limit.
  const counterKey = `count:${installId}:${todayUTC(now)}`;
  const current = parseInt((await env.RATE_LIMIT.get(counterKey)) ?? "0", 10) || 0;
  if (current >= DAILY_LIMIT) {
    return { ok: false, status: 429, error: "daily push limit reached" };
  }
  await env.RATE_LIMIT.put(counterKey, String(current + 1), {
    expirationTtl: COUNTER_TTL_SECONDS,
  });

  return { ok: true };
}

export const _internal = { DAILY_LIMIT, COUNTER_TTL_SECONDS, hashSecret, todayUTC };
