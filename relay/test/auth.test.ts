import { describe, it, expect } from "vitest";
import {
  authenticateAndRateLimit,
  isWellFormedId,
  isWellFormedSecret,
  _internal,
} from "../src/auth";
import { MemKV } from "./helpers";

const ID = "a".repeat(16);
const SECRET = "s".repeat(40);

function env() {
  return { RATE_LIMIT: new MemKV() as unknown as KVNamespace };
}

describe("well-formed checks", () => {
  it("accepts 16-64 hex ids", () => {
    expect(isWellFormedId("a".repeat(16))).toBe(true);
    expect(isWellFormedId("0123456789abcdef".repeat(4))).toBe(true); // 64
  });
  it("rejects bad ids", () => {
    expect(isWellFormedId("a".repeat(15))).toBe(false);
    expect(isWellFormedId("a".repeat(65))).toBe(false);
    expect(isWellFormedId("XYZ")).toBe(false);
    expect(isWellFormedId(123 as unknown)).toBe(false);
  });
  it("requires >=32 char secret", () => {
    expect(isWellFormedSecret("x".repeat(32))).toBe(true);
    expect(isWellFormedSecret("x".repeat(31))).toBe(false);
  });
});

describe("authenticateAndRateLimit", () => {
  it("pins the secret on first use and accepts the matching pair", async () => {
    const e = env();
    expect((await authenticateAndRateLimit(e, ID, SECRET)).ok).toBe(true);
    expect((await authenticateAndRateLimit(e, ID, SECRET)).ok).toBe(true);
  });

  it("rejects a mismatched secret for an existing id (401)", async () => {
    const e = env();
    await authenticateAndRateLimit(e, ID, SECRET);
    const r = await authenticateAndRateLimit(e, ID, "z".repeat(40));
    expect(r).toMatchObject({ ok: false, status: 401 });
  });

  it("rejects malformed credentials (400)", async () => {
    const e = env();
    expect(await authenticateAndRateLimit(e, "bad", SECRET)).toMatchObject({
      ok: false,
      status: 400,
    });
    expect(await authenticateAndRateLimit(e, ID, "short")).toMatchObject({
      ok: false,
      status: 400,
    });
  });

  it("enforces the daily limit (429 after 300)", async () => {
    const e = env();
    const now = new Date("2026-06-10T12:00:00Z");
    // Pre-seed the counter to the cap so we don't loop 300×.
    const key = `count:${ID}:2026-06-10`;
    await e.RATE_LIMIT.put(key, String(_internal.DAILY_LIMIT));
    // Need to pin auth first (separate call would be rejected on count).
    await e.RATE_LIMIT.put(`auth:${ID}`, await _internal.hashSecret(SECRET));
    const r = await authenticateAndRateLimit(e, ID, SECRET, now);
    expect(r).toMatchObject({ ok: false, status: 429 });
  });

  it("increments the per-day counter", async () => {
    const e = env();
    const now = new Date("2026-06-10T12:00:00Z");
    await authenticateAndRateLimit(e, ID, SECRET, now);
    await authenticateAndRateLimit(e, ID, SECRET, now);
    expect(await e.RATE_LIMIT.get("count:" + ID + ":2026-06-10")).toBe("2");
  });
});
