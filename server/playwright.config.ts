import { defineConfig, devices } from "@playwright/test";

const TEST_TOKEN = process.env.CCM_TEST_TOKEN || "ccm-dev-test-playwright-x1234567";
const CCM_PORT = parseInt(process.env.CCM_TEST_PORT || "8901", 10);
const BASE_URL = `http://127.0.0.1:${CCM_PORT}`;

export default defineConfig({
  testDir: "./test/playwright",
  outputDir: "./playwright-report/test-results",
  globalSetup: "./test/playwright/global-setup.ts",
  reporter: [
    ["list"],
    ["json", { outputFile: "./playwright-report/results.json" }],
    ["html", { outputFolder: "./playwright-report/html", open: "never" }],
  ],
  use: {
    baseURL: BASE_URL,
    trace: "on-first-retry",
    screenshot: "only-on-failure",
    video: "retain-on-failure",
  },
  projects: [
    {
      name: "chromium",
      use: { ...devices["Desktop Chrome"] },
    },
  ],
  webServer: {
    command: `CCM_TOKEN=${TEST_TOKEN} CCM_PORT=${CCM_PORT} npm run dev`,
    url: BASE_URL,
    reuseExistingServer: false,
    timeout: 20_000,
    env: {
      CCM_TOKEN: TEST_TOKEN,
      CCM_PORT: String(CCM_PORT),
      CCM_WEB_UI: "true",
      CCM_WORKSPACE_ROOT: "/tmp",
    },
  },
  timeout: 60_000,
  expect: { timeout: 10_000 },
  forbidOnly: Boolean(process.env.CI),
  retries: process.env.CI ? 2 : 0,
  workers: 1,
});
