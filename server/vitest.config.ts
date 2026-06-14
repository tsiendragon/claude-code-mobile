import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Unit tests only. The Playwright e2e specs under test/playwright import
    // @playwright/test (not a vitest context) and are run via `npm run test:e2e`.
    // Without this exclude, vitest's default `.spec.ts` glob would try to collect
    // webui.spec.ts and fail at import time.
    exclude: ["**/node_modules/**", "**/dist/**", "test/playwright/**"],
  },
});
