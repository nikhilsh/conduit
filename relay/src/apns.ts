// APNs transport: sign an ES256 provider JWT and POST the notification to
// Apple. Runs entirely on WebCrypto so it works on the Workers runtime.

import { importES256PrivateKey, signJwt } from "./jwt";
import type { PushPayload, SendResult } from "./types";

export interface ApnsEnv {
  APNS_KEY: string; // .p8 PEM
  APNS_KEY_ID: string;
  APNS_TEAM_ID: string;
  APNS_TOPIC?: string; // default sh.nikhil.conduit
}

const DEFAULT_TOPIC = "sh.nikhil.conduit";

// Apple accepts a provider token aged 20–60 min; refresh at ~45 min. Cached
// at module scope so warm Worker invocations reuse it (one sign per ~45 min
// per isolate, not per request).
const JWT_TTL_MS = 45 * 60 * 1000;
interface CachedJwt {
  token: string;
  expiresAt: number;
  keyId: string;
  teamId: string;
}
let cachedJwt: CachedJwt | null = null;

async function providerToken(env: ApnsEnv, now: number): Promise<string> {
  if (
    cachedJwt &&
    cachedJwt.expiresAt > now &&
    cachedJwt.keyId === env.APNS_KEY_ID &&
    cachedJwt.teamId === env.APNS_TEAM_ID
  ) {
    return cachedJwt.token;
  }
  const key = await importES256PrivateKey(env.APNS_KEY);
  const token = await signJwt(
    { kid: env.APNS_KEY_ID },
    { iss: env.APNS_TEAM_ID, iat: Math.floor(now / 1000) },
    key,
    "ES256",
  );
  cachedJwt = {
    token,
    expiresAt: now + JWT_TTL_MS,
    keyId: env.APNS_KEY_ID,
    teamId: env.APNS_TEAM_ID,
  };
  return token;
}

// Build the APNs JSON body. For a plain alert we send a standard aps dict;
// privacy-mode content-free payloads still carry a title/body so the OS can
// render something, plus the broker's session_id/box for the tap deep-link.
function buildBody(payload: PushPayload): string {
  const isLiveActivity = payload.category === "liveactivity";
  if (isLiveActivity) {
    const event = payload.event ?? "update";
    const contentState = payload.content_state ?? { title: payload.title, body: payload.body };

    if (event === "start") {
      // Push-to-start: APNs requires attributes-type + attributes + alert in aps.
      // attributes_type MUST be "TurnActivityAttributes" and attributes keys MUST
      // be "agentName"/"sessionID"/"sessionName" — the OS rejects typos silently.
      // See: TurnActivityAttributes.swift, broker emitLAStart, PLAN-push-to-start-la.md §2.3.
      return JSON.stringify({
        aps: {
          timestamp: Math.floor(Date.now() / 1000),
          event: "start",
          "content-state": contentState,
          "attributes-type": payload.attributes_type,
          attributes: payload.attributes,
          alert: payload.alert ?? { title: payload.title, body: payload.body },
        },
        session_id: payload.session_id,
        box: payload.box,
      });
    }

    // Live Activity update/end: forward the broker-supplied content_state verbatim
    // into aps."content-state" so the iOS TurnActivityContentState Codable
    // receives exactly the keys the broker computed. Use the broker's event
    // field ("update"|"end"); fall back to "update" if absent (forward compat).
    //
    // For "end": set dismissal-date to now + 5 min. Without it iOS keeps the
    // final state on the lock screen for up to 4 hours (Apple default).
    const nowSec = Math.floor(Date.now() / 1000);
    const aps: Record<string, unknown> = {
      timestamp: nowSec,
      event,
      "content-state": contentState,
    };
    if (event === "end") {
      aps["dismissal-date"] = nowSec + 5 * 60;
    }
    return JSON.stringify({
      aps,
      session_id: payload.session_id,
      box: payload.box,
    });
  }
  // App-level categories ("approval"/"input"/"ask") ride in aps.category so iOS
  // can attach registered notification actions; plain alerts omit it.
  // "ask" pushes also carry options[] and mutable-content:1 so the
  // UNNotificationServiceExtension runs and registers dynamic action labels.
  const apsCategory =
    payload.category && payload.category !== "alert" ? payload.category : undefined;
  const hasOptions = Array.isArray(payload.options) && payload.options.length > 0;
  return JSON.stringify({
    aps: {
      alert: { title: payload.title, body: payload.body },
      sound: "default",
      ...(apsCategory ? { category: apsCategory } : {}),
      ...(hasOptions ? { "mutable-content": 1 } : {}),
    },
    session_id: payload.session_id,
    box: payload.box,
    ...(apsCategory ? { category: apsCategory } : {}),
    ...(hasOptions ? { options: payload.options } : {}),
  });
}

export async function sendApns(
  env: ApnsEnv,
  token: string,
  payload: PushPayload,
  pushEnv: "production" | "sandbox",
  now: number = Date.now(),
): Promise<SendResult> {
  const jwt = await providerToken(env, now);
  const baseTopic = env.APNS_TOPIC || DEFAULT_TOPIC;
  const isLiveActivity = payload.category === "liveactivity";
  const topic = isLiveActivity ? `${baseTopic}.push-type.liveactivity` : baseTopic;
  const host =
    pushEnv === "sandbox" ? "api.sandbox.push.apple.com" : "api.push.apple.com";

  // Live Activity update/end use priority 5 (energy-efficient; Apple throttles
  // priority-10 LA pushes heavily). Push-to-start uses priority 10 — it is a
  // user-facing alert-equivalent and must land immediately. Alert pushes keep 10.
  const apnsPriority = isLiveActivity && payload.event !== "start" ? "5" : "10";

  const resp = await fetch(`https://${host}/3/device/${token}`, {
    method: "POST",
    headers: {
      authorization: `bearer ${jwt}`,
      "apns-topic": topic,
      "apns-push-type": isLiveActivity ? "liveactivity" : "alert",
      "apns-priority": apnsPriority,
      "content-type": "application/json",
    },
    body: buildBody(payload),
  });

  if (resp.status === 200) {
    return { ok: true };
  }

  // Apple returns a JSON {reason} body on failure.
  let reason = "";
  try {
    const j = (await resp.json()) as { reason?: string };
    reason = j.reason ?? "";
  } catch {
    // non-JSON / empty body — fall through with the status code
  }

  if (resp.status === 410 || reason === "Unregistered" || reason === "BadDeviceToken") {
    return { ok: false, gone: true, detail: reason || "unregistered" };
  }
  return { ok: false, gone: false, detail: `apns ${resp.status} ${reason}`.trim() };
}

export const _internal = { providerToken, buildBody, resetCache: () => (cachedJwt = null) };
