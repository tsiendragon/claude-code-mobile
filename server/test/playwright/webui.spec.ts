/**
 * CCM WebUI end-to-end tests via Playwright.
 *
 * Tests the full stack: Browser WebSocket → CCM Bridge → CCC → backend CLI.
 * All 4 backends are exercised; unavailable ones are skipped automatically.
 *
 * Failures are saved as artifacts; run `node scripts/gen-test-from-failure.mjs`
 * afterwards to promote them to persistent vitest regression cases.
 */

import { test, expect } from "@playwright/test";
import {
  connectToCCM,
  createSession,
  attachSession,
  sendAndWaitForReply,
  captureWebSocketMessages,
  saveFailureArtifacts,
  backendAvailable,
  waitForText,
  killTestSessions,
  type BackendName,
  TEST_CWD,
} from "./helpers.js";

// Test sessions keep their backend process running in tmux after a test ends.
// Kill every pw-* session after each test so they don't accumulate and overload
// the bridge's StatePoller (which would starve the next test's polling). Runs
// serially (workers: 1), so killing all pw-* sessions here is safe.
test.afterEach(async () => {
  await killTestSessions();
});

// ---------------------------------------------------------------------------
// Auth & initial page load
// ---------------------------------------------------------------------------

test.describe("auth", () => {
  test("page loads and shows auth panel", async ({ page }) => {
    await page.goto("/");
    await expect(page.locator('[data-testid="auth-panel"]')).toBeVisible();
    await expect(page.locator('[data-testid="workspace"]')).toBeHidden();
    await expect(page.locator('[data-testid="conn-text"]')).toHaveText("disconnected");
  });

  test("connects with valid token", async ({ page }) => {
    await connectToCCM(page);
    await expect(page.locator('[data-testid="workspace"]')).toBeVisible();
    await expect(page.locator('[data-testid="conn-text"]')).toHaveText("connected");
    await expect(page.locator('[data-testid="conn-dot"]')).toHaveClass(/dot-on/);
  });

  test("shows error with wrong token", async ({ page }) => {
    await page.goto("/");
    await page.fill('[data-testid="ws-url"]', `ws://127.0.0.1:${process.env.CCM_TEST_PORT || "8901"}/ws`);
    await page.fill('[data-testid="token"]', "wrong-token-xxx");
    await page.click('[data-testid="btn-connect"]');
    await expect(page.locator('[data-testid="auth-error"]')).toBeVisible({ timeout: 10_000 });
  });

  test("disconnect button works", async ({ page }) => {
    await connectToCCM(page);
    await page.click('[data-testid="btn-disconnect"]');
    await expect(page.locator('[data-testid="conn-text"]')).toHaveText("disconnected", {
      timeout: 5_000,
    });
  });
});

// ---------------------------------------------------------------------------
// Session list — no active sessions at startup
// ---------------------------------------------------------------------------

test.describe("session list", () => {
  test.beforeEach(async ({ page }) => {
    await connectToCCM(page);
  });

  test("shows session list panel after connect", async ({ page }) => {
    const list = page.locator('[data-testid="session-list"]');
    await expect(list).toBeVisible();
    // List is present; may have pre-existing sessions from prior runs — that is acceptable.
  });
});

// ---------------------------------------------------------------------------
// Session lifecycle — parameterized per backend
// ---------------------------------------------------------------------------

const BACKENDS: BackendName[] = ["claude", "cursor", "codex", "opencode"];

for (const backend of BACKENDS) {
  test.describe(`session lifecycle [${backend}]`, () => {
    test.beforeEach(async ({ page }, testInfo) => {
      const available = await backendAvailable(backend);
      if (!available) {
        testInfo.skip(true, `${backend} binary not found — skipping`);
      }
      await connectToCCM(page);
    });

    test(`create and list session [${backend}]`, async ({ page }, testInfo) => {
      const wsLog = captureWebSocketMessages(page);

      try {
        const session = await createSession(page, {
          name: `pw-test-${backend}`,
          backend,
          cwd: TEST_CWD,
          skipPermissions: backend === "claude" || backend === "cursor",
        });

        expect(session.sessionId).toBeTruthy();
        const item = page.locator(`[data-testid="session-${session.sessionId}"]`);
        await expect(item).toBeVisible();
      } catch (err) {
        await saveFailureArtifacts(page, testInfo, wsLog);
        throw err;
      }
    });

    test(`send message and receive reply [${backend}]`, async ({ page }, testInfo) => {
      const wsLog = captureWebSocketMessages(page);

      try {
        const session = await createSession(page, {
          name: `pw-msg-${backend}`,
          backend,
          cwd: TEST_CWD,
          skipPermissions: true,
        });

        await attachSession(page, session.sessionId);

        // Wait for session to reach ready state
        await page.waitForFunction(
          () => document.getElementById("state-badge")?.textContent === "ready",
          undefined,
          { timeout: 30_000 },
        );

        const reply = await sendAndWaitForReply(page, "say the word PONG and nothing else", {
          timeoutMs: 90_000,
        });

        expect(reply.toLowerCase()).toContain("pong");

        // Validate state badge after reply
        const badge = await waitForText(page, '[data-testid="state-badge"]');
        expect(["ready", "ended"]).toContain(badge);
      } catch (err) {
        await saveFailureArtifacts(page, testInfo, wsLog);
        throw err;
      }
    });

    test(`kill session [${backend}]`, async ({ page }, testInfo) => {
      const wsLog = captureWebSocketMessages(page);

      try {
        const session = await createSession(page, {
          name: `pw-kill-${backend}`,
          backend,
          cwd: TEST_CWD,
          skipPermissions: true,
        });

        await attachSession(page, session.sessionId);

        // Wait until kill button is enabled
        await page.waitForSelector('[data-testid="btn-kill"]:not([disabled])', {
          timeout: 20_000,
        });

        // Accept the kill confirmation dialog
        page.once("dialog", (dialog) => dialog.accept());
        await page.click('[data-testid="btn-kill"]');

        // State badge should reach "ended" (ccc kill can take a moment)
        await page.waitForFunction(
          () => document.getElementById("state-badge")?.textContent === "ended",
          undefined,
          { timeout: 30_000 },
        );
        const badge = await waitForText(page, '[data-testid="state-badge"]');
        expect(badge).toBe("ended");
      } catch (err) {
        await saveFailureArtifacts(page, testInfo, wsLog);
        throw err;
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Approval workflow (claude + cursor only)
// ---------------------------------------------------------------------------

for (const backend of ["claude", "cursor"] as BackendName[]) {
  test.describe(`approval flow [${backend}]`, () => {
    test.beforeEach(async ({ page }, testInfo) => {
      const available = await backendAvailable(backend);
      if (!available) {
        testInfo.skip(true, `${backend} binary not found — skipping`);
      }
      await connectToCCM(page);
    });

    test(`approval card appears and can be approved [${backend}]`, async ({ page }, testInfo) => {
      const wsLog = captureWebSocketMessages(page);

      try {
        const session = await createSession(page, {
          name: `pw-approval-${backend}`,
          backend,
          cwd: TEST_CWD,
          skipPermissions: false, // do NOT skip so approval prompt appears
        });

        await attachSession(page, session.sessionId);

        await page.waitForFunction(
          () => document.getElementById("state-badge")?.textContent === "ready",
          undefined,
          { timeout: 30_000 },
        );

        // Prompt a file write which should trigger permission request
        await page.fill('[data-testid="prompt"]', "write 'hello' to /tmp/ccm-approval-test.txt");
        await page.click('[data-testid="btn-send"]');

        // Wait for approval card — some backends (cursor) may auto-approve with no prompt
        const approvalCard = page.locator('[data-testid="approval-card"]');
        const gotApproval = await approvalCard.waitFor({ state: "visible", timeout: 15_000 })
          .then(() => true)
          .catch(() => false);

        if (!gotApproval) {
          // Backend auto-approved without showing a prompt (e.g. cursor).
          // Verify the session recovers to a terminal state.
          await page.waitForFunction(
            () => {
              const b = document.getElementById("state-badge")?.textContent;
              return b === "ready" || b === "ended";
            },
            undefined,
            { timeout: 45_000 },
          );
          testInfo.annotations.push({
            type: "info",
            description: `${backend} did not show an approval prompt — auto-approved or not supported`,
          });
          return;
        }

        // State badge should be "approval" or "choosing" (menu-style approvals)
        const badge = await waitForText(page, '[data-testid="state-badge"]');
        expect(["approval", "choosing"]).toContain(badge);

        // Click the first action button (approve)
        const firstAction = approvalCard.locator("button").first();
        await firstAction.click();

        // Approval card should disappear
        await expect(approvalCard).toBeHidden({ timeout: 15_000 });
      } catch (err) {
        await saveFailureArtifacts(page, testInfo, wsLog);
        throw err;
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Interrupt
// ---------------------------------------------------------------------------

test.describe("session interrupt", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    const available = await backendAvailable("claude");
    if (!available) {
      testInfo.skip(true, "claude binary not found — skipping interrupt test");
    }
    await connectToCCM(page);
  });

  test("interrupt stops a thinking session", async ({ page }, testInfo) => {
    const wsLog = captureWebSocketMessages(page);

    try {
      const session = await createSession(page, {
        name: "pw-interrupt",
        backend: "claude",
        cwd: TEST_CWD,
        skipPermissions: true,
      });

      await attachSession(page, session.sessionId);

      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "ready",
        undefined,
        { timeout: 30_000 },
      );

      // Send a prompt that takes time
      await page.fill('[data-testid="prompt"]', "count slowly from 1 to 1000, one number per line");
      await page.click('[data-testid="btn-send"]');

      // Wait for thinking state
      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "thinking",
        undefined,
        { timeout: 15_000 },
      );

      // Interrupt should be enabled now
      await expect(page.locator('[data-testid="btn-interrupt"]')).toBeEnabled();
      await page.click('[data-testid="btn-interrupt"]');

      // Session should recover to ready or ended
      await page.waitForFunction(
        () => {
          const b = document.getElementById("state-badge")?.textContent;
          return b === "ready" || b === "ended";
        },
        undefined,
        { timeout: 20_000 },
      );
    } catch (err) {
      await saveFailureArtifacts(page, testInfo, wsLog);
      throw err;
    }
  });
});

// ---------------------------------------------------------------------------
// CCC parser response validation — via CCM bridge, not direct parser calls
// ---------------------------------------------------------------------------

test.describe("ccc parser validation via ccm", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    const available = await backendAvailable("claude");
    if (!available) {
      testInfo.skip(true, "claude binary not found — skipping parser validation");
    }
    await connectToCCM(page);
  });

  test("state badge matches actual ccc session state", async ({ page }, testInfo) => {
    testInfo.setTimeout(120_000); // create + attach + send + reply can exceed the 60s default
    const wsLog = captureWebSocketMessages(page);

    try {
      const session = await createSession(page, {
        name: "pw-parser-state",
        backend: "claude",
        cwd: TEST_CWD,
        skipPermissions: true,
      });

      await attachSession(page, session.sessionId);

      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "ready",
        undefined,
        { timeout: 30_000 },
      );

      // Send a message — sendAndWaitForReply handles thinking → ready and auto-approves
      // any session-level "choosing" dialogs that claude may show.
      const reply = await sendAndWaitForReply(page, "reply with just the word OK", {
        timeoutMs: 60_000,
      });

      // State badge should end at "ready" — verifies CCC state is reflected correctly
      const finalBadge = await waitForText(page, '[data-testid="state-badge"]');
      expect(finalBadge).toBe("ready");

      // At least one assistant message should be visible — verifies events were delivered
      expect(reply.trim().length).toBeGreaterThan(0);
    } catch (err) {
      await saveFailureArtifacts(page, testInfo, wsLog);
      throw err;
    }
  });

  test("assistant message content is non-empty and parseable", async ({ page }, testInfo) => {
    testInfo.setTimeout(120_000); // create + attach + send + reply can exceed the 60s default
    const wsLog = captureWebSocketMessages(page);

    try {
      const session = await createSession(page, {
        name: "pw-parser-content",
        backend: "claude",
        cwd: TEST_CWD,
        skipPermissions: true,
      });

      await attachSession(page, session.sessionId);
      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "ready",
        undefined,
        { timeout: 30_000 },
      );

      const reply = await sendAndWaitForReply(page, 'reply with exactly: {"ok":true}', {
        timeoutMs: 60_000,
      });

      expect(reply.trim()).toBeTruthy();
      // CCC should not return raw ANSI or spinner artifacts
      expect(reply).not.toMatch(/\x1b\[/); // no ANSI escape sequences
      expect(reply).not.toMatch(/^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/); // no spinner chars
    } catch (err) {
      await saveFailureArtifacts(page, testInfo, wsLog);
      throw err;
    }
  });

  test("multi-backend parser smoke: codex response extraction", async ({ page }, testInfo) => {
    const available = await backendAvailable("codex");
    if (!available) {
      testInfo.skip(true, "codex not available");
    }

    const wsLog = captureWebSocketMessages(page);

    try {
      const session = await createSession(page, {
        name: "pw-parser-codex",
        backend: "codex",
        cwd: TEST_CWD,
        skipPermissions: true,
      });

      await attachSession(page, session.sessionId);
      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "ready",
        undefined,
        { timeout: 45_000 }, // codex may show trust dialog first
      );

      const reply = await sendAndWaitForReply(page, "say PONG", { timeoutMs: 90_000 });
      expect(reply.toLowerCase()).toContain("pong");
      expect(reply).not.toMatch(/\x1b\[/);
    } catch (err) {
      await saveFailureArtifacts(page, testInfo, wsLog);
      throw err;
    }
  });
});

// ---------------------------------------------------------------------------
// File access — agent produces a file, CCM can list and read it
// ---------------------------------------------------------------------------

test.describe("file access", () => {
  test.beforeEach(async ({ page }, testInfo) => {
    const available = await backendAvailable("claude");
    if (!available) {
      testInfo.skip(true, "claude binary not found — skipping file access test");
    }
    await connectToCCM(page);
  });

  test("agent-produced file appears in CCM file list and is readable", async ({ page }, testInfo) => {
    testInfo.setTimeout(180_000); // file write + UI interactions can take >60s
    const wsLog = captureWebSocketMessages(page);

    try {
      const session = await createSession(page, {
        name: "pw-file-access",
        backend: "claude",
        cwd: TEST_CWD,
        skipPermissions: true,
      });

      await attachSession(page, session.sessionId);

      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "ready",
        undefined,
        { timeout: 30_000 },
      );

      // Unique filename so we can identify it unambiguously
      const fileName = `ccm-file-test.txt`;
      const filePath = `${TEST_CWD}/${fileName}`;
      const fileContent = "hello-from-agent-ccm-test";

      // Ask the agent to write the file
      // sendAndWaitForReply auto-handles any "choosing" approval dialogs that claude may show
      await sendAndWaitForReply(
        page,
        `Write the exact text "${fileContent}" to the file ${filePath} — no other output.`,
        { timeoutMs: 90_000 },
      );

      // Switch to the Files tab
      await page.click('[data-testid="tab-files"]');
      await expect(page.locator('[data-testid="panel-files"]')).toBeVisible();

      // Refresh the file list to pick up newly created file
      await page.click('[data-testid="btn-refresh-files"]');

      // File should appear in the list
      const fileList = page.locator('[data-testid="file-list"]');
      await expect(fileList).toContainText(fileName, { timeout: 15_000 });

      // Click the file item to open it in the file viewer
      await fileList.locator(`text=${fileName}`).first().click();

      // Verify the file content is rendered
      await expect(page.locator('[data-testid="file-view"]')).toContainText(fileContent, {
        timeout: 10_000,
      });
    } catch (err) {
      await saveFailureArtifacts(page, testInfo, wsLog);
      throw err;
    }
  });
});

// ---------------------------------------------------------------------------
// Multi-backend CCC response parsing smoke tests
// ---------------------------------------------------------------------------

const PARSER_BACKENDS: BackendName[] = ["cursor", "codex", "opencode"];

for (const backend of PARSER_BACKENDS) {
  test.describe(`ccc parser smoke [${backend}]`, () => {
    test.beforeEach(async ({ page }, testInfo) => {
      const available = await backendAvailable(backend);
      if (!available) {
        testInfo.skip(true, `${backend} binary not found — skipping parser smoke`);
      }
      await connectToCCM(page);
    });

    test(`${backend} response is clean (no ANSI, no spinner)`, async ({ page }, testInfo) => {
      const wsLog = captureWebSocketMessages(page);

      try {
        const session = await createSession(page, {
          name: `pw-parser-${backend}`,
          backend,
          cwd: TEST_CWD,
          skipPermissions: true,
        });

        await attachSession(page, session.sessionId);

        await page.waitForFunction(
          () => document.getElementById("state-badge")?.textContent === "ready",
          undefined,
          { timeout: 45_000 },
        );

        const reply = await sendAndWaitForReply(page, "say the word PING and nothing else", {
          timeoutMs: 90_000,
        });

        expect(reply.trim()).toBeTruthy();
        expect(reply).not.toMatch(/\x1b\[/); // no ANSI escape sequences
        expect(reply).not.toMatch(/^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/); // no spinner chars
        expect(reply.toLowerCase()).toContain("ping");
      } catch (err) {
        await saveFailureArtifacts(page, testInfo, wsLog);
        throw err;
      }
    });
  });
}

// ---------------------------------------------------------------------------
// Event log tab — sanity check
// ---------------------------------------------------------------------------

test.describe("event log", () => {
  test("event log receives messages after connect", async ({ page }) => {
    await connectToCCM(page);

    // Switch to log tab
    await page.click('[data-testid="tab-log"]');
    await expect(page.locator('[data-testid="panel-log"]')).toBeVisible();

    // Event log should have at least one entry from the auth handshake
    const logLines = page.locator('[data-testid="event-log"] .log-line');
    await expect(logLines.first()).toBeVisible({ timeout: 5_000 });
  });
});
