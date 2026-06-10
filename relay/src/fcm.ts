// FCM HTTP v1 transport: mint an OAuth2 access token from a service-account
// JSON (JWT-grant flow, RS256 via WebCrypto), then POST the message.

import { importRS256PrivateKey, signJwt } from "./jwt";
import type { PushPayload, SendResult } from "./types";

export interface FcmEnv {
  FCM_SERVICE_ACCOUNT: string; // service-account JSON
}

interface ServiceAccount {
  client_email: string;
  private_key: string;
  project_id: string;
  token_uri?: string;
}

const FCM_SCOPE = "https://www.googleapis.com/auth/firebase.messaging";
const DEFAULT_TOKEN_URI = "https://oauth2.googleapis.com/token";

// Cached OAuth token, module-scoped, reused across warm invocations until it
// nears expiry (60s safety margin). Keyed by the SA client_email so a secret
// rotation invalidates the cache.
interface CachedToken {
  token: string;
  expiresAt: number;
  client: string;
}
let cachedToken: CachedToken | null = null;

function parseServiceAccount(raw: string): ServiceAccount {
  const sa = JSON.parse(raw) as ServiceAccount;
  if (!sa.client_email || !sa.private_key || !sa.project_id) {
    throw new Error("FCM_SERVICE_ACCOUNT missing client_email/private_key/project_id");
  }
  return sa;
}

async function accessToken(sa: ServiceAccount, now: number): Promise<string> {
  if (cachedToken && cachedToken.expiresAt > now && cachedToken.client === sa.client_email) {
    return cachedToken.token;
  }
  const tokenUri = sa.token_uri || DEFAULT_TOKEN_URI;
  const iat = Math.floor(now / 1000);
  const key = await importRS256PrivateKey(sa.private_key);
  const assertion = await signJwt(
    {},
    {
      iss: sa.client_email,
      scope: FCM_SCOPE,
      aud: tokenUri,
      iat,
      exp: iat + 3600,
    },
    key,
    "RS256",
  );

  const resp = await fetch(tokenUri, {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded" },
    body:
      "grant_type=urn%3Aietf%3Aparams%3Aoauth%3Agrant-type%3Ajwt-bearer&assertion=" +
      encodeURIComponent(assertion),
  });
  if (!resp.ok) {
    throw new Error(`fcm oauth ${resp.status}`);
  }
  const j = (await resp.json()) as { access_token: string; expires_in: number };
  cachedToken = {
    token: j.access_token,
    // 60s safety margin before the stated expiry.
    expiresAt: now + (j.expires_in - 60) * 1000,
    client: sa.client_email,
  };
  return j.access_token;
}

function buildMessage(token: string, payload: PushPayload): unknown {
  // Stringify the data values (FCM data fields must be strings). Omit empty.
  const data: Record<string, string> = {};
  if (payload.session_id) data.session_id = payload.session_id;
  if (payload.box) data.box = payload.box;
  if (payload.category) data.category = payload.category;
  return {
    message: {
      token,
      notification: { title: payload.title, body: payload.body },
      data,
      android: { priority: "high" },
    },
  };
}

export async function sendFcm(
  env: FcmEnv,
  token: string,
  payload: PushPayload,
  now: number = Date.now(),
): Promise<SendResult> {
  const sa = parseServiceAccount(env.FCM_SERVICE_ACCOUNT);
  const oauth = await accessToken(sa, now);

  const resp = await fetch(
    `https://fcm.googleapis.com/v1/projects/${sa.project_id}/messages:send`,
    {
      method: "POST",
      headers: {
        authorization: `Bearer ${oauth}`,
        "content-type": "application/json",
      },
      body: JSON.stringify(buildMessage(token, payload)),
    },
  );

  if (resp.status === 200) {
    return { ok: true };
  }

  // FCM v1 errors carry {error:{status, message, details:[{errorCode}]}}.
  let status = "";
  let errorCode = "";
  try {
    const j = (await resp.json()) as {
      error?: {
        status?: string;
        details?: Array<{ errorCode?: string }>;
      };
    };
    status = j.error?.status ?? "";
    for (const d of j.error?.details ?? []) {
      if (d.errorCode) errorCode = d.errorCode;
    }
  } catch {
    // non-JSON body — fall through with the HTTP status
  }

  const gone =
    resp.status === 404 ||
    status === "NOT_FOUND" ||
    status === "UNREGISTERED" ||
    errorCode === "UNREGISTERED";
  if (gone) {
    return { ok: false, gone: true, detail: errorCode || status || "unregistered" };
  }
  return { ok: false, gone: false, detail: `fcm ${resp.status} ${status}`.trim() };
}

export const _internal = {
  parseServiceAccount,
  accessToken,
  buildMessage,
  resetCache: () => (cachedToken = null),
};
