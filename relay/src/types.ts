// Shared request/response shapes for the relay. The /v1/send contract is the
// agreed seam between the broker's relaySender (WS-P.1) and this Worker.

export interface PushPayload {
  title: string;
  body: string;
  session_id?: string;
  box?: string;
  category?: "alert" | "liveactivity";
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
