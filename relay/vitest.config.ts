import { defineConfig } from "vitest/config";

// Plain Node unit tests with mocked globals (fetch / crypto via WebCrypto).
// Deliberately NOT the @cloudflare/vitest-pool-workers pool so `npm test`
// runs with zero Cloudflare login / miniflare setup. The Worker code uses
// only WebCrypto + fetch, both available on Node 20's globals, so unit
// coverage is faithful without the workerd runtime.
export default defineConfig({
  test: {
    include: ["test/**/*.test.ts"],
    environment: "node",
  },
});
