import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { sendFcm, _internal } from "../src/fcm";
import { makeRsaPem, decodeJwt, b64urlToBytes, mockFetch } from "./helpers";

let pem: string;
let publicKey: CryptoKey;

beforeEach(async () => {
  _internal.resetCache();
  ({ pem, publicKey } = await makeRsaPem());
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function env() {
  return {
    FCM_SERVICE_ACCOUNT: JSON.stringify({
      client_email: "push@conduit.iam.gserviceaccount.com",
      private_key: pem,
      project_id: "conduit-proj",
      token_uri: "https://oauth2.googleapis.com/token",
    }),
  };
}

const payload = { title: "Conduit", body: "needs you", session_id: "s1", box: "b1" };

function oauthOk() {
  return new Response(JSON.stringify({ access_token: "ya29.fake", expires_in: 3600 }), {
    status: 200,
  });
}

describe("FCM OAuth grant JWT", () => {
  it("signs an RS256 grant JWT with scope/aud and verifies", async () => {
    let assertion = "";
    mockFetch([
      [
        "oauth2.googleapis.com",
        () => oauthOk(),
      ],
    ]);
    (globalThis.fetch as any).mockImplementation(async (_i: any, init: any) => {
      const body = init.body as string;
      assertion = decodeURIComponent(body.split("assertion=")[1]);
      return oauthOk();
    });

    await _internal.accessToken(_internal.parseServiceAccount(env().FCM_SERVICE_ACCOUNT), Date.now());
    const { header, claims } = decodeJwt(assertion);
    expect(header.alg).toBe("RS256");
    expect(claims.scope).toContain("firebase.messaging");
    expect(claims.aud).toBe("https://oauth2.googleapis.com/token");

    const [h, c, sig] = assertion.split(".");
    const ok = await crypto.subtle.verify(
      { name: "RSASSA-PKCS1-v1_5" },
      publicKey,
      b64urlToBytes(sig),
      new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it("caches the access token across calls", async () => {
    const fn = mockFetch([["oauth2.googleapis.com", () => oauthOk()]]);
    const sa = _internal.parseServiceAccount(env().FCM_SERVICE_ACCOUNT);
    const now = Date.now();
    await _internal.accessToken(sa, now);
    await _internal.accessToken(sa, now + 1000);
    expect(fn).toHaveBeenCalledTimes(1);
  });
});

describe("sendFcm", () => {
  it("POSTs to the project messages:send endpoint and returns ok", async () => {
    let url = "";
    let bodyObj: any = null;
    mockFetch([
      ["oauth2.googleapis.com", () => oauthOk()],
      ["fcm.googleapis.com", () => new Response(JSON.stringify({ name: "ok" }), { status: 200 })],
    ]);
    const base = (globalThis.fetch as any).getMockImplementation();
    (globalThis.fetch as any).mockImplementation(async (i: any, init: any) => {
      if (i.toString().includes("fcm.googleapis.com")) {
        url = i.toString();
        bodyObj = JSON.parse(init.body);
      }
      return base(i, init);
    });

    const r = await sendFcm(env(), "devicetoken", payload);
    expect(r.ok).toBe(true);
    expect(url).toContain("/v1/projects/conduit-proj/messages:send");
    expect(bodyObj.message.token).toBe("devicetoken");
    expect(bodyObj.message.data.session_id).toBe("s1");
    expect(bodyObj.message.data.box).toBe("b1");
  });

  it("maps UNREGISTERED to gone", async () => {
    mockFetch([
      ["oauth2.googleapis.com", () => oauthOk()],
      [
        "fcm.googleapis.com",
        () =>
          new Response(
            JSON.stringify({ error: { status: "NOT_FOUND", details: [{ errorCode: "UNREGISTERED" }] } }),
            { status: 404 },
          ),
      ],
    ]);
    const r = await sendFcm(env(), "tok", payload);
    expect(r).toMatchObject({ ok: false, gone: true });
  });

  it("maps other errors to non-gone failure", async () => {
    mockFetch([
      ["oauth2.googleapis.com", () => oauthOk()],
      [
        "fcm.googleapis.com",
        () => new Response(JSON.stringify({ error: { status: "INTERNAL" } }), { status: 500 }),
      ],
    ]);
    const r = await sendFcm(env(), "tok", payload);
    expect(r).toMatchObject({ ok: false, gone: false });
  });
});
