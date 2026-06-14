import { type Page, type TestInfo, type WebSocket } from "@playwright/test";
import * as fs from "node:fs/promises";
import * as path from "node:path";

export const CCM_TEST_TOKEN = process.env.CCM_TEST_TOKEN || "ccm-dev-test-playwright-x1234567";
export const CCM_PORT = process.env.CCM_TEST_PORT || "8901";
export const WS_URL = `ws://127.0.0.1:${CCM_PORT}/ws`;
export const TEST_CWD = process.env.CCM_TEST_CWD || "/tmp";

export type BackendName = "claude" | "cursor" | "codex" | "opencode";

/** Captured WebSocket message envelope */
export interface WsCapture {
  dir: "out" | "in";
  ts: number;
  payload: unknown;
}

/** Result of a session creation */
export interface SessionInfo {
  sessionId: string;
  name: string;
}

/**
 * Connect to CCM WebUI and authenticate.
 * On success, the #workspace element is visible.
 */
export async function connectToCCM(page: Page): Promise<void> {
  await page.goto("/");
  // ws-url auto-fills from defaultWsUrl(); override to use our test port
  await page.fill('[data-testid="ws-url"]', WS_URL);
  await page.fill('[data-testid="token"]', CCM_TEST_TOKEN);
  await page.click('[data-testid="btn-connect"]');
  await page.waitForSelector('[data-testid="workspace"]:not([hidden])', {
    timeout: 12_000,
  });
  // Wait for refreshSessions to populate the session list
  // renderSessionList always produces at least one <li> (empty-state placeholder or actual sessions)
  await page.waitForFunction(
    () => (document.querySelector('[data-testid="session-list"]')?.children.length ?? 0) > 0,
    undefined,
    { timeout: 10_000 },
  ).catch(() => {/* no sessions is also fine */});
}

/**
 * Create a new CCC session via the WebUI run form.
 * Returns the session ID extracted from the newly added session-list item.
 */
export async function createSession(
  page: Page,
  opts: {
    name: string;
    backend: BackendName;
    cwd?: string;
    skipPermissions?: boolean;
  },
): Promise<SessionInfo> {
  const cwd = opts.cwd ?? TEST_CWD;

  // Open the create-session details panel
  const details = page.locator("details.create-box");
  const isOpen = await details.getAttribute("open");
  if (isOpen === null) {
    await details.locator("summary").click();
  }

  await page.fill('[data-testid="run-name"]', opts.name);
  await page.selectOption('[data-testid="run-backend"]', opts.backend);

  // Switch to manual cwd mode
  await page.selectOption('[data-testid="run-target"]', "cwd");
  await page.waitForSelector('[data-testid="run-cwd"]:not([hidden])', {
    timeout: 3_000,
  });
  await page.fill('[data-testid="run-cwd"]', cwd);

  if (opts.skipPermissions) {
    await page.check('[data-testid="run-skip"]');
  }

  // Snapshot existing session IDs; connectToCCM already waited for the list to stabilize
  const existingIds = new Set<string>();
  for (const item of await page.locator('[data-testid^="session-"]').all()) {
    const tid = await item.getAttribute("data-testid") ?? "";
    if (tid.startsWith("session-")) existingIds.add(tid.slice("session-".length));
  }

  await page.click('[data-testid="btn-run"]');

  // After Run, runSession calls refreshSessions which adds the new session to the DOM.
  // Wait for a session item whose ID was NOT in existingIds.
  const handle = await page.waitForFunction(
    (knownIds: string[]) => {
      const known = new Set(knownIds);
      for (const el of document.querySelectorAll('[data-testid^="session-"]')) {
        const id = (el.getAttribute("data-testid") ?? "").slice("session-".length);
        if (id && !known.has(id)) return id;
      }
      return null;
    },
    [...existingIds],
    { timeout: 20_000 },
  );
  const sessionId = (await handle.jsonValue()) as string;
  if (!sessionId) throw new Error(`createSession: no new session appeared after creating "${opts.name}"`);
  return { sessionId, name: opts.name };
}

/**
 * Attach to a session and wait for the chat header to update.
 */
export async function attachSession(page: Page, sessionId: string): Promise<void> {
  await page.click(`[data-testid="session-${sessionId}"]`);
  await page.waitForFunction(
    (id) => {
      const badge = document.getElementById("state-badge");
      return badge && badge.textContent !== "";
    },
    sessionId,
    { timeout: 25_000 },
  );
}

/**
 * Send a message in the active session and wait for an assistant reply.
 * Returns the assistant reply text.
 */
export async function sendAndWaitForReply(
  page: Page,
  message: string,
  opts: { timeoutMs?: number } = {},
): Promise<string> {
  const timeout = opts.timeoutMs ?? 120_000;

  // Wait for composer to be enabled (session must be in ready state)
  await page.waitForSelector('[data-testid="prompt"]:not([disabled])', {
    timeout: 30_000,
  });

  // Snapshot existing message count so we can wait for a NEW message (not a startup banner).
  const initialMsgCount = await page.locator('[data-testid="msg-assistant"]').count();

  await page.fill('[data-testid="prompt"]', message);
  await page.click('[data-testid="btn-send"]');

  // Wait for state badge to go "thinking" then back to a terminal state
  await page.waitForFunction(
    () => document.getElementById("state-badge")?.textContent === "thinking",
    undefined,
    { timeout: 15_000 },
  );
  await page.waitForFunction(
    () => {
      const badge = document.getElementById("state-badge")?.textContent;
      return badge === "ready" || badge === "approval" || badge === "choosing" || badge === "ended";
    },
    undefined,
    { timeout },
  );

  // If claude shows a session-level "allow all edits" choice dialog (choosing state),
  // auto-approve the first option and wait for ready. This happens when claude detects
  // MCP setup issues even with --dangerously-skip-permissions.
  const badgeAfterWait = await page.locator("#state-badge").textContent().catch(() => "");
  if (badgeAfterWait === "choosing") {
    const approvalCard = page.locator('[data-testid="approval-card"]');
    if (await approvalCard.isVisible({ timeout: 2_000 }).catch(() => false)) {
      await approvalCard.locator("button").first().click();
      await page.waitForFunction(
        () => {
          const b = document.getElementById("state-badge")?.textContent;
          return b === "ready" || b === "approval" || b === "ended";
        },
        undefined,
        { timeout: 60_000 },
      );
    }
    // The "choosing" dialog consumes the original message — if no new message appeared,
    // resend the original prompt so Claude can actually answer it.
    const countAfterChoosing = await page.locator('[data-testid="msg-assistant"]').count();
    if (countAfterChoosing <= initialMsgCount) {
      await page.waitForSelector('[data-testid="prompt"]:not([disabled])', { timeout: 15_000 });
      await page.fill('[data-testid="prompt"]', message);
      await page.click('[data-testid="btn-send"]');
      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "thinking",
        undefined,
        { timeout: 15_000 },
      );
      await page.waitForFunction(
        () => {
          const b = document.getElementById("state-badge")?.textContent;
          return b === "ready" || b === "approval" || b === "ended";
        },
        undefined,
        { timeout },
      );
    }
  }

  // Wait for a NEW assistant message to appear (count must exceed the pre-send snapshot).
  // This prevents returning a stale startup banner that was already in the DOM.
  await page.waitForFunction(
    (initial) => (document.querySelectorAll('[data-testid="msg-assistant"]').length) > initial,
    initialMsgCount,
    { timeout: 30_000 },
  ).catch(() => {});

  // Fallback: if still no new message and badge is "ready", a choosing dialog may have
  // raced through to "ready" before we could detect it, consuming the original prompt.
  // Resend once to ensure Claude gets a chance to actually answer.
  const currentCount = await page.locator('[data-testid="msg-assistant"]').count();
  if (currentCount <= initialMsgCount) {
    const currentBadge = await page.locator("#state-badge").textContent().catch(() => "");
    if (currentBadge === "ready") {
      await page.waitForSelector('[data-testid="prompt"]:not([disabled])', {
        timeout: 10_000,
      }).catch(() => {});
      await page.fill('[data-testid="prompt"]', message);
      await page.click('[data-testid="btn-send"]');
      await page.waitForFunction(
        () => document.getElementById("state-badge")?.textContent === "thinking",
        undefined,
        { timeout: 15_000 },
      ).catch(() => {});
      await page.waitForFunction(
        () => {
          const b = document.getElementById("state-badge")?.textContent;
          return b === "ready" || b === "approval" || b === "ended";
        },
        undefined,
        { timeout },
      ).catch(() => {});
      await page.waitForFunction(
        (initial) =>
          (document.querySelectorAll('[data-testid="msg-assistant"]').length) > initial,
        initialMsgCount,
        { timeout: 30_000 },
      ).catch(() => {});
    }
  }

  // Extract last assistant message
  const msgs = page.locator('[data-testid="msg-assistant"]');
  const count = await msgs.count();
  if (count === 0) return "";
  return (await msgs.last().textContent()) ?? "";
}

/**
 * Start capturing all WebSocket messages exchanged on the page.
 * Returns a shared array that accumulates messages in real time.
 */
export function captureWebSocketMessages(page: Page): WsCapture[] {
  const log: WsCapture[] = [];
  page.on("websocket", (ws: WebSocket) => {
    ws.on("framesent", (frame) => {
      try {
        log.push({ dir: "out", ts: Date.now(), payload: JSON.parse(frame.payload as string) });
      } catch {
        log.push({ dir: "out", ts: Date.now(), payload: frame.payload });
      }
    });
    ws.on("framereceived", (frame) => {
      try {
        log.push({ dir: "in", ts: Date.now(), payload: JSON.parse(frame.payload as string) });
      } catch {
        log.push({ dir: "in", ts: Date.now(), payload: frame.payload });
      }
    });
  });
  return log;
}

/**
 * On test failure, save screenshot + WS message log to the test output dir
 * so gen-test-from-failure.mjs can turn them into vitest cases.
 */
export async function saveFailureArtifacts(
  page: Page,
  testInfo: TestInfo,
  wsLog: WsCapture[],
): Promise<void> {
  const dir = testInfo.outputDir;
  await fs.mkdir(dir, { recursive: true });

  // Write the WS log + meta FIRST: they don't depend on the page, and the
  // screenshot below can throw if the page was already closed (e.g. on a test
  // timeout). Writing artifacts in this order guarantees the captured WS frames
  // — the most useful debugging signal — are never lost to a screenshot error.
  const wsPath = path.join(dir, "ws-messages.json");
  await fs.writeFile(wsPath, JSON.stringify(wsLog, null, 2));

  const metaPath = path.join(dir, "failure-meta.json");
  await fs.writeFile(
    metaPath,
    JSON.stringify(
      {
        title: testInfo.title,
        file: testInfo.file,
        status: testInfo.status,
        error: testInfo.error?.message,
        timestamp: new Date().toISOString(),
      },
      null,
      2,
    ),
  );

  const screenshotPath = path.join(dir, "failure.png");
  await page.screenshot({ path: screenshotPath, fullPage: true }).catch(() => {/* page may be closed */});
}

/**
 * Kill leaked CCC sessions whose names start with `prefix` (default "pw-").
 *
 * Test sessions do NOT die when a test ends — the backend process keeps running
 * in its tmux session. Left alone, they accumulate across runs (we have seen 100+)
 * and every `session.list` re-registers them all into the bridge's StatePoller,
 * which then polls each live session every 1–3s. That continuous subprocess load
 * (ccc read → tmux capture-pane) starves the active test's polling and causes
 * intermittent reply timeouts. Killing them keeps each test isolated.
 *
 * Best-effort: silently ignores a missing `ccc` binary or parse errors.
 */
export async function killTestSessions(prefix = "pw-"): Promise<number> {
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const exec = promisify(execFile);
  try {
    const { stdout } = await exec("ccc", ["ps", "--json"], { maxBuffer: 8 * 1024 * 1024 });
    const sessions = JSON.parse(stdout) as Array<{ name?: string }>;
    const names = sessions
      .map((s) => s.name)
      .filter((n): n is string => typeof n === "string" && n.startsWith(prefix));
    await Promise.all(names.map((n) => exec("ccc", ["kill", n]).catch(() => {})));
    return names.length;
  } catch {
    return 0;
  }
}

/** Check if a backend binary is available on PATH. */
export async function backendAvailable(backend: BackendName): Promise<boolean> {
  const binMap: Record<BackendName, string> = {
    claude: "claude",
    cursor: "cursor-agent",
    codex: "codex",
    opencode: "opencode",
  };
  const { execFile } = await import("node:child_process");
  const { promisify } = await import("node:util");
  const exec = promisify(execFile);
  try {
    await exec("which", [binMap[backend]]);
    return true;
  } catch {
    return false;
  }
}

/** Wait for an element and return its text, throwing if it doesn't appear. */
export async function waitForText(
  page: Page,
  selector: string,
  opts: { timeout?: number } = {},
): Promise<string> {
  const el = page.locator(selector);
  await el.waitFor({ state: "visible", timeout: opts.timeout ?? 10_000 });
  return (await el.textContent()) ?? "";
}
