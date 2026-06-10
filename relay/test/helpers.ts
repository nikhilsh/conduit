// Test helpers: an in-memory KV stub and a freshly generated EC P-256 key
// exported as PKCS#8 PEM. The key is generated at test time and never
// written to disk — no committed key material.

import { vi } from "vitest";

export class MemKV {
  store = new Map<string, string>();

  async get(key: string): Promise<string | null> {
    return this.store.has(key) ? (this.store.get(key) as string) : null;
  }

  async put(key: string, value: string, _opts?: { expirationTtl?: number }): Promise<void> {
    this.store.set(key, value);
  }

  async delete(key: string): Promise<void> {
    this.store.delete(key);
  }
}

function toPem(der: ArrayBuffer, label: string): string {
  const bytes = new Uint8Array(der);
  let binary = "";
  for (let i = 0; i < bytes.length; i++) binary += String.fromCharCode(bytes[i]);
  const b64 = btoa(binary).replace(/(.{64})/g, "$1\n");
  return `-----BEGIN ${label}-----\n${b64}\n-----END ${label}-----\n`;
}

// Generate a throwaway EC P-256 keypair; return the private key as PKCS#8 PEM
// (the .p8 format Apple hands out) plus the live CryptoKey objects for
// verifying signatures in tests.
export async function makeP256Pem(): Promise<{
  pem: string;
  publicKey: CryptoKey;
}> {
  const kp = (await crypto.subtle.generateKey(
    { name: "ECDSA", namedCurve: "P-256" },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", kp.privateKey);
  return { pem: toPem(pkcs8, "PRIVATE KEY"), publicKey: kp.publicKey };
}

// Generate a throwaway RSA-2048 keypair as PKCS#8 PEM (FCM service-account
// shape) plus the public key for signature verification.
export async function makeRsaPem(): Promise<{
  pem: string;
  publicKey: CryptoKey;
}> {
  const kp = (await crypto.subtle.generateKey(
    {
      name: "RSASSA-PKCS1-v1_5",
      modulusLength: 2048,
      publicExponent: new Uint8Array([1, 0, 1]),
      hash: "SHA-256",
    },
    true,
    ["sign", "verify"],
  )) as CryptoKeyPair;
  const pkcs8 = await crypto.subtle.exportKey("pkcs8", kp.privateKey);
  return { pem: toPem(pkcs8, "PRIVATE KEY"), publicKey: kp.publicKey };
}

export function b64urlToBytes(s: string): ArrayBuffer {
  const b64 = s.replace(/-/g, "+").replace(/_/g, "/");
  const pad = b64.length % 4 === 0 ? "" : "=".repeat(4 - (b64.length % 4));
  const bin = atob(b64 + pad);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out.buffer;
}

export function decodeJwt(jwt: string): { header: any; claims: any } {
  const [h, c] = jwt.split(".");
  const dec = (s: string) => JSON.parse(new TextDecoder().decode(b64urlToBytes(s)));
  return { header: dec(h), claims: dec(c) };
}

// Install a fetch mock that routes by URL substring to a handler returning
// a Response. Returns the vi mock for assertions.
export function mockFetch(routes: Array<[string, () => Response | Promise<Response>]>) {
  const fn = vi.fn(async (input: RequestInfo | URL, _init?: RequestInit) => {
    const url = typeof input === "string" ? input : input.toString();
    for (const [needle, handler] of routes) {
      if (url.includes(needle)) return handler();
    }
    throw new Error(`unexpected fetch: ${url}`);
  });
  vi.stubGlobal("fetch", fn);
  return fn;
}
