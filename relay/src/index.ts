// Conduit push relay — a stateless Cloudflare Worker that holds the vendor
// APNs .p8 + a min-scope FCM service account and pass-throughs the broker's
// {token, payload} to Apple / Google. No token storage; the only state is a
// per-install rate counter + auth-pin in KV. See relay/README.md for the
// provisioning runbook and docs/PLAN-PUSH.md (WS-P.2) for the design.

import { authenticateAndRateLimit } from "./auth";
import type { RateLimitEnv } from "./auth";
import { sendApns } from "./apns";
import type { ApnsEnv } from "./apns";
import { sendFcm } from "./fcm";
import type { FcmEnv } from "./fcm";
import type { PushPayload, SendRequest, SendResult } from "./types";

export interface Env extends RateLimitEnv, ApnsEnv, FcmEnv {}

function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json" },
  });
}

function validPayload(p: unknown): p is PushPayload {
  if (typeof p !== "object" || p === null) return false;
  const o = p as Record<string, unknown>;
  if (typeof o.title !== "string" || typeof o.body !== "string") return false;
  if (o.session_id !== undefined && typeof o.session_id !== "string") return false;
  if (o.box !== undefined && typeof o.box !== "string") return false;
  if (
    o.category !== undefined &&
    o.category !== "alert" &&
    o.category !== "approval" &&
    o.category !== "input" &&
    o.category !== "liveactivity"
  ) {
    return false;
  }
  // Live Activity optional fields.
  if (o.event !== undefined && o.event !== "update" && o.event !== "end" && o.event !== "start") {
    return false;
  }
  if (o.content_state !== undefined && (typeof o.content_state !== "object" || o.content_state === null)) {
    return false;
  }
  // Push-to-start optional fields (event="start" only, but validated regardless).
  if (o.attributes_type !== undefined && typeof o.attributes_type !== "string") return false;
  if (o.attributes !== undefined && (typeof o.attributes !== "object" || o.attributes === null)) return false;
  if (o.alert !== undefined) {
    if (typeof o.alert !== "object" || o.alert === null) return false;
    const alert = o.alert as Record<string, unknown>;
    if (typeof alert.title !== "string" || typeof alert.body !== "string") return false;
  }
  return true;
}

function validRequest(b: unknown): b is SendRequest {
  if (typeof b !== "object" || b === null) return false;
  const o = b as Record<string, unknown>;
  if (o.platform !== "apns" && o.platform !== "fcm") return false;
  if (typeof o.token !== "string" || o.token.length === 0) return false;
  if (o.env !== undefined && o.env !== "production" && o.env !== "sandbox") return false;
  return validPayload(o.payload);
}

export async function handleSend(req: Request, env: Env): Promise<Response> {
  let body: unknown;
  try {
    body = await req.json();
  } catch {
    return json(400, { error: "invalid JSON body" });
  }

  if (!validRequest(body)) {
    return json(400, { error: "malformed request" });
  }
  const { install_id, install_secret, platform, token, payload } = body;

  const auth = await authenticateAndRateLimit(env, install_id, install_secret);
  if (!auth.ok) {
    return json(auth.status, { error: auth.error });
  }

  // AdHoc/TestFlight builds use the PRODUCTION APNs environment, so default
  // to production unless the caller explicitly asks for sandbox.
  const pushEnv = body.env ?? "production";

  let result: SendResult;
  try {
    result =
      platform === "apns"
        ? await sendApns(env, token, payload, pushEnv)
        : await sendFcm(env, token, payload);
  } catch (e) {
    // Never include payload contents in the error (privacy).
    const detail = e instanceof Error ? e.message : "send failed";
    return json(502, { error: detail });
  }

  if (result.ok) {
    return json(200, { ok: true });
  }
  if (result.gone) {
    // The broker maps 410 → push.ErrTokenGone and prunes the token.
    return json(410, { error: "token gone" });
  }
  return json(502, { error: result.detail });
}

export default {
  async fetch(req: Request, env: Env): Promise<Response> {
    const url = new URL(req.url);
    if (req.method === "POST" && url.pathname === "/v1/send") {
      return handleSend(req, env);
    }
    if (req.method === "GET" && url.pathname === "/health") {
      return json(200, { ok: true });
    }
    return json(404, { error: "not found" });
  },
};
