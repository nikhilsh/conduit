// WebCrypto helpers for signing JWTs on the Cloudflare Workers runtime.
// Deliberately no Node-only crypto APIs — everything goes through the
// standard `crypto.subtle` available in workerd and Node 20.

const enc = new TextEncoder();

export function base64urlEncode(data: ArrayBuffer | Uint8Array | string): string {
  let bytes: Uint8Array;
  if (typeof data === "string") {
    bytes = enc.encode(data);
  } else if (data instanceof Uint8Array) {
    bytes = data;
  } else {
    bytes = new Uint8Array(data);
  }
  let binary = "";
  for (let i = 0; i < bytes.length; i++) {
    binary += String.fromCharCode(bytes[i]);
  }
  return btoa(binary).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

function pemToArrayBuffer(pem: string): ArrayBuffer {
  // Strip PEM armor and whitespace, then base64-decode the DER body.
  const body = pem
    .replace(/-----BEGIN [^-]+-----/g, "")
    .replace(/-----END [^-]+-----/g, "")
    .replace(/\s+/g, "");
  const binary = atob(body);
  const buf = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) {
    buf[i] = binary.charCodeAt(i);
  }
  return buf.buffer;
}

// Import an EC P-256 (.p8 PKCS#8) private key for ES256 signing.
export async function importES256PrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(pem),
    { name: "ECDSA", namedCurve: "P-256" },
    false,
    ["sign"],
  );
}

// Import an RSA (PKCS#8) private key for RS256 signing (FCM service account).
export async function importRS256PrivateKey(pem: string): Promise<CryptoKey> {
  return crypto.subtle.importKey(
    "pkcs8",
    pemToArrayBuffer(pem),
    { name: "RSASSA-PKCS1-v1_5", hash: "SHA-256" },
    false,
    ["sign"],
  );
}

// Sign a JWT with the given header/claims using an already-imported key.
// alg drives both the header value and the WebCrypto sign params.
export async function signJwt(
  header: Record<string, unknown>,
  claims: Record<string, unknown>,
  key: CryptoKey,
  alg: "ES256" | "RS256",
): Promise<string> {
  const signingInput =
    base64urlEncode(JSON.stringify({ ...header, alg, typ: "JWT" })) +
    "." +
    base64urlEncode(JSON.stringify(claims));

  const params =
    alg === "ES256"
      ? { name: "ECDSA", hash: "SHA-256" }
      : { name: "RSASSA-PKCS1-v1_5" };

  const sig = await crypto.subtle.sign(params, key, enc.encode(signingInput));
  return signingInput + "." + base64urlEncode(sig);
}
