// Shared request/response shapes for the relay. The /v1/send contract is the
// agreed seam between the broker's relaySender (WS-P.1) and this Worker.

export interface PushPayload {
  title: string;
  body: string;
  session_id?: string;
  box?: string;
  // "approval" / "input" are app-level pending-input categories: forwarded to
  // APNs as aps.category (drives actionable Approve/Deny buttons on iOS) and
  // already passed through to FCM as a data key. "alert"/absent = plain alert.
  category?: "alert" | "approval" | "input" | "liveactivity";
  // Live Activity fields (category="liveactivity" only).
  // event is the APNs activity event: "update", "end", or "start".
  event?: "update" | "end" | "start";
  // content_state is the broker-supplied TurnActivityContentState object
  // forwarded verbatim into aps."content-state". Keys must match the iOS
  // Codable (epoch-millis Int timestamps, see shared contract).
  content_state?: Record<string, unknown>;
  // Push-to-start fields (event="start" only).
  // attributes_type MUST be exactly "TurnActivityAttributes" — the OS uses
  // this to route the start push to the correct Activity type. A typo is
  // rejected by the OS with no client-visible error.
  attributes_type?: string;
  // attributes keys MUST be exactly "agentName", "sessionID", "sessionName"
  // to match the TurnActivityAttributes struct property names.
  attributes?: Record<string, unknown>;
  // alert is required by Apple for push-to-start: { title, body }.
  alert?: { title: string; body: string };
}

export interface SendRequest {
  install_id: string;
  install_secret: string;
  platform: "apns" | "fcm";
  token: string;
  env?: "production" | "sandbox";
  payload: PushPayload;
}

// Result of a single upstream delivery attempt. `gone` flags a permanently
// dead token (APNs 410 / FCM UNREGISTERED) which the relay surfaces to the
// broker as HTTP 410 → push.ErrTokenGone.
export type SendResult =
  | { ok: true }
  | { ok: false; gone: boolean; detail: string };
