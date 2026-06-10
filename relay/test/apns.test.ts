import { describe, it, expect, beforeEach, afterEach, vi } from "vitest";
import { sendApns, _internal } from "../src/apns";
import { makeP256Pem, decodeJwt, b64urlToBytes, mockFetch } from "./helpers";

let pem: string;
let publicKey: CryptoKey;

beforeEach(async () => {
  _internal.resetCache();
  ({ pem, publicKey } = await makeP256Pem());
});

afterEach(() => {
  vi.unstubAllGlobals();
});

function env() {
  return {
    APNS_KEY: pem,
    APNS_KEY_ID: "ABC1234567",
    APNS_TEAM_ID: "EHW7L3679R",
    APNS_TOPIC: "sh.nikhil.conduit",
  };
}

const payload = { title: "Conduit", body: "a session needs you", session_id: "s1" };

describe("APNs provider JWT", () => {
  it("has ES256 header, kid, iss, and a verifiable signature", async () => {
    const jwt = await _internal.providerToken(env(), Date.now());
    const { header, claims } = decodeJwt(jwt);
    expect(header.alg).toBe("ES256");
    expect(header.kid).toBe("ABC1234567");
    expect(claims.iss).toBe("EHW7L3679R");
    expect(typeof claims.iat).toBe("number");

    const [h, c, sig] = jwt.split(".");
    const ok = await crypto.subtle.verify(
      { name: "ECDSA", hash: "SHA-256" },
      publicKey,
      b64urlToBytes(sig),
      new TextEncoder().encode(`${h}.${c}`),
    );
    expect(ok).toBe(true);
  });

  it("caches within the TTL and refreshes after it", async () => {
    const now = Date.now();
    const a = await _internal.providerToken(env(), now);
    const b = await _internal.providerToken(env(), now + 1000);
    expect(b).toBe(a);
    const c = await _internal.providerToken(env(), now + 50 * 60 * 1000);
    expect(c).not.toBe(a);
  });
});

describe("sendApns", () => {
  it("POSTs to production host with alert headers and returns ok on 200", async () => {
    let captured: { url: string; headers: Headers } | null = null;
    const fetchMock = mockFetch([["push.apple.com", () => new Response(null, { status: 200 })]]);
    fetchMock.mockImplementation(async (input: RequestInfo | URL, init?: RequestInit) => {
      captured = { url: input.toString(), headers: new Headers(init?.headers) };
      return new Response(null, { status: 200 });
    });

    const r = await sendApns(env(), "devtoken", payload, "production");
    expect(r.ok).toBe(true);
    expect(captured!.url).toContain("https://api.push.apple.com/3/device/devtoken");
    expect(captured!.headers.get("apns-push-type")).toBe("alert");
    expect(captured!.headers.get("apns-topic")).toBe("sh.nikhil.conduit");
    expect(captured!.headers.get("apns-priority")).toBe("10");
    expect(captured!.headers.get("authorization")).toMatch(/^bearer /);
  });

  it("uses the sandbox host when env=sandbox", async () => {
    let url = "";
    mockFetch([
      ["sandbox.push.apple.com", () => new Response(null, { status: 200 })],
    ]);
    (globalThis.fetch as any).mockImplementation(async (i: any) => {
      url = i.toString();
      return new Response(null, { status: 200 });
    });
    const r = await sendApns(env(), "tok", payload, "sandbox");
    expect(r.ok).toBe(true);
    expect(url).toContain("api.sandbox.push.apple.com");
  });

  it("uses the liveactivity topic suffix + push-type for category=liveactivity", async () => {
    let headers: Headers | null = null;
    mockFetch([["push.apple.com", () => new Response(null, { status: 200 })]]);
    (globalThis.fetch as any).mockImplementation(async (_i: any, init: any) => {
      headers = new Headers(init?.headers);
      return new Response(null, { status: 200 });
    });
    await sendApns(
      env(),
      "tok",
      { ...payload, category: "liveactivity" },
      "production",
    );
    expect(headers!.get("apns-topic")).toBe("sh.nikhil.conduit.push-type.liveactivity");
    expect(headers!.get("apns-push-type")).toBe("liveactivity");
  });

  it("maps 410 Unregistered to gone", async () => {
    mockFetch([
      [
        "push.apple.com",
        () => new Response(JSON.stringify({ reason: "Unregistered" }), { status: 410 }),
      ],
    ]);
    const r = await sendApns(env(), "tok", payload, "production");
    expect(r).toMatchObject({ ok: false, gone: true });
  });

  it("maps other errors to non-gone failure", async () => {
    mockFetch([
      [
        "push.apple.com",
        () => new Response(JSON.stringify({ reason: "TooManyRequests" }), { status: 429 }),
      ],
    ]);
    const r = await sendApns(env(), "tok", payload, "production");
    expect(r).toMatchObject({ ok: false, gone: false });
  });
});
