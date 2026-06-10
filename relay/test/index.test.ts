import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import worker, { handleSend, type Env } from "../src/index";
import { _internal as apnsInternal } from "../src/apns";
import { _internal as fcmInternal } from "../src/fcm";
import { MemKV, makeP256Pem, makeRsaPem, mockFetch } from "./helpers";

const ID = "deadbeef".repeat(2); // 16 hex
const SECRET = "k".repeat(40);

let env: Env;

beforeEach(async () => {
  apnsInternal.resetCache();
  fcmInternal.resetCache();
  const { pem: ecPem } = await makeP256Pem();
  const { pem: rsaPem } = await makeRsaPem();
  env = {
    RATE_LIMIT: new MemKV() as unknown as KVNamespace,
    APNS_KEY: ecPem,
    APNS_KEY_ID: "ABC1234567",
    APNS_TEAM_ID: "EHW7L3679R",
    APNS_TOPIC: "sh.nikhil.conduit",
    FCM_SERVICE_ACCOUNT: JSON.stringify({
      client_email: "p@x.iam.gserviceaccount.com",
      private_key: rsaPem,
      project_id: "proj",
    }),
  };
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function sendReq(body: unknown): Request {
  return new Request("https://push.conduit.nikhil.sh/v1/send", {
    method: "POST",
    body: JSON.stringify(body),
  });
}

const validBody = {
  install_id: ID,
  install_secret: SECRET,
  platform: "apns" as const,
  token: "devtoken",
  payload: { title: "Conduit", body: "needs you", session_id: "s1" },
};

describe("routing", () => {
  it("404s unknown routes", async () => {
    const r = await worker.fetch(new Request("https://x/nope"), env);
    expect(r.status).toBe(404);
  });
  it("health check", async () => {
    const r = await worker.fetch(new Request("https://x/health"), env);
    expect(r.status).toBe(200);
  });
});

describe("handleSend validation", () => {
  it("400 on invalid JSON", async () => {
    const r = await handleSend(
      new Request("https://x/v1/send", { method: "POST", body: "{" }),
      env,
    );
    expect(r.status).toBe(400);
  });
  it("400 on malformed request (bad platform)", async () => {
    const r = await handleSend(sendReq({ ...validBody, platform: "telegram" }), env);
    expect(r.status).toBe(400);
  });
  it("400 on missing payload title", async () => {
    const r = await handleSend(sendReq({ ...validBody, payload: { body: "x" } }), env);
    expect(r.status).toBe(400);
  });
  it("400 on bad install_id", async () => {
    const r = await handleSend(sendReq({ ...validBody, install_id: "nope" }), env);
    expect(r.status).toBe(400);
  });
});

describe("handleSend happy + error mapping (APNs)", () => {
  it("200 forwards to APNs and defaults to production", async () => {
    let url = "";
    mockFetch([["push.apple.com", () => new Response(null, { status: 200 })]]);
    (globalThis.fetch as any).mockImplementation(async (i: any) => {
      url = i.toString();
      return new Response(null, { status: 200 });
    });
    const r = await handleSend(sendReq(validBody), env);
    expect(r.status).toBe(200);
    expect(url).toContain("api.push.apple.com");
  });

  it("410 when APNs reports Unregistered", async () => {
    mockFetch([
      [
        "push.apple.com",
        () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }),
      ],
    ]);
    const r = await handleSend(sendReq(validBody), env);
    expect(r.status).toBe(410);
  });

  it("502 on other upstream error without leaking payload", async () => {
    mockFetch([
      ["push.apple.com", () => new Response(JSON.stringify({ reason: "InternalServerError" }), { status: 500 })],
    ]);
    const r = await handleSend(sendReq(validBody), env);
    expect(r.status).toBe(502);
    const text = await r.text();
    expect(text).not.toContain("needs you");
  });
});

describe("handleSend FCM path", () => {
  it("200 forwards to FCM messages:send", async () => {
    let url = "";
    mockFetch([
      ["oauth2.googleapis.com", () => new Response(JSON.stringify({ access_token: "t", expires_in: 3600 }), { status: 200 })],
      ["fcm.googleapis.com", () => new Response(JSON.stringify({ name: "ok" }), { status: 200 })],
    ]);
    const base = (globalThis.fetch as any).getMockImplementation();
    (globalThis.fetch as any).mockImplementation(async (i: any, init: any) => {
      if (i.toString().includes("fcm.googleapis")) url = i.toString();
      return base(i, init);
    });
    const r = await handleSend(
      sendReq({ ...validBody, platform: "fcm", token: "fcmtoken" }),
      env,
    );
    expect(r.status).toBe(200);
    expect(url).toContain("/v1/projects/proj/messages:send");
  });
});

describe("auth + rate limit through handleSend", () => {
  it("401 on secret mismatch for a pinned id", async () => {
    mockFetch([["push.apple.com", () => new Response(null, { status: 200 })]]);
    await handleSend(sendReq(validBody), env);
    const r = await handleSend(sendReq({ ...validBody, install_secret: "z".repeat(40) }), env);
    expect(r.status).toBe(401);
  });

  it("429 when over the daily cap", async () => {
    mockFetch([["push.apple.com", () => new Response(null, { status: 200 })]]);
    const kv = env.RATE_LIMIT as unknown as MemKV;
    const today = new Date().toISOString().slice(0, 10);
    // pin auth then max the counter
    await handleSend(sendReq(validBody), env);
    kv.store.set(`count:${ID}:${today}`, "300");
    const r = await handleSend(sendReq(validBody), env);
    expect(r.status).toBe(429);
  });
});
