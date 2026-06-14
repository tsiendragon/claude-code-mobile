#!/usr/bin/env node
/**
 * gen-test-from-failure.mjs
 *
 * Reads Playwright failure artifacts from playwright-report/test-results/
 * and generates:
 *   1. Vitest regression cases → test/playwright-regressions.test.ts
 *   2. CCC parser fixtures     → ../../claude-code-connector/tests/fixtures/<NNN>-pw-<slug>/
 *
 * Run after a Playwright test run that produced failures:
 *   node scripts/gen-test-from-failure.mjs
 */

import { readdir, readFile, writeFile, mkdir, stat } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __dir = path.dirname(fileURLToPath(import.meta.url));
const SERVER_DIR = path.resolve(__dir, "..");
const RESULTS_DIR = path.join(SERVER_DIR, "playwright-report", "test-results");
const REGRESSION_FILE = path.join(SERVER_DIR, "test", "playwright-regressions.test.ts");
const CCC_FIXTURES_DIR = path.resolve(SERVER_DIR, "../../claude-code-connector/tests/fixtures");

// ---------------------------------------------------------------------------
// Utilities
// ---------------------------------------------------------------------------

function slugify(str) {
  return str
    .toLowerCase()
    .replace(/[^a-z0-9]+/g, "-")
    .replace(/^-|-$/g, "")
    .slice(0, 48);
}

async function exists(p) {
  return stat(p).then(() => true).catch(() => false);
}

async function nextFixtureNumber() {
  if (!(await exists(CCC_FIXTURES_DIR))) return "023";
  const dirs = await readdir(CCC_FIXTURES_DIR);
  const nums = dirs
    .map((d) => parseInt(d.slice(0, 3), 10))
    .filter((n) => !isNaN(n));
  const max = nums.length ? Math.max(...nums) : 22;
  return String(max + 1).padStart(3, "0");
}

// ---------------------------------------------------------------------------
// Load failure artifacts
// ---------------------------------------------------------------------------

async function loadFailures() {
  if (!(await exists(RESULTS_DIR))) {
    console.log("No playwright-report/test-results/ directory found.");
    return [];
  }

  const entries = await readdir(RESULTS_DIR, { withFileTypes: true });
  const failures = [];

  for (const entry of entries) {
    if (!entry.isDirectory()) continue;
    const dir = path.join(RESULTS_DIR, entry.name);
    const metaPath = path.join(dir, "failure-meta.json");
    const wsPath = path.join(dir, "ws-messages.json");

    if (!(await exists(metaPath))) continue;

    const meta = JSON.parse(await readFile(metaPath, "utf8"));
    const wsMessages = (await exists(wsPath))
      ? JSON.parse(await readFile(wsPath, "utf8"))
      : [];

    failures.push({ dir, meta, wsMessages, artifactDir: entry.name });
  }

  return failures;
}

// ---------------------------------------------------------------------------
// Generate vitest regression test case
// ---------------------------------------------------------------------------

function renderVitestCase(failure) {
  const { meta, wsMessages } = failure;
  const title = meta.title || "unknown test";
  const error = meta.error || "unknown error";
  const timestamp = meta.timestamp || new Date().toISOString();

  // Extract the sequence of RPC calls from WS out-messages
  const rpcCalls = wsMessages
    .filter((m) => m.dir === "out")
    .map((m) => {
      const p = m.payload;
      if (typeof p === "object" && p !== null && "type" in p) {
        return { type: p.type, params: p };
      }
      return null;
    })
    .filter(Boolean);

  // Extract events received from WS in-messages
  const eventsReceived = wsMessages
    .filter((m) => m.dir === "in")
    .filter((m) => {
      const p = m.payload;
      return typeof p === "object" && p !== null && p.type === "event";
    })
    .map((m) => m.payload?.event)
    .filter(Boolean);

  return `
  // Captured from Playwright failure: "${title}"
  // Timestamp: ${timestamp}
  // Error: ${error}
  it.skip(${JSON.stringify("regression: " + title)}, async () => {
    // TODO: implement regression test based on failure
    // RPC sequence:
    // ${rpcCalls.map((r) => JSON.stringify(r?.type)).join(", ")}
    // Events received:
    // ${eventsReceived.map((e) => JSON.stringify(e?.kind)).join(", ")}
    //
    // Steps to reproduce:
    // 1. Connect to CCM with valid token
    // 2. ${rpcCalls.map((r) => `Call ${r?.type}`).join("\n    // ")}
    // Expected: test passes without error
    // Actual: ${error}
    expect(true).toBe(false); // remove this and implement the test
  });`;
}

// ---------------------------------------------------------------------------
// Detect parser failures in WS log
// ---------------------------------------------------------------------------

function detectParserFailure(failure) {
  const { wsMessages, meta } = failure;

  // Look for state_changed events with unexpected states
  const stateChanges = wsMessages
    .filter((m) => m.dir === "in")
    .filter((m) => m.payload?.type === "event" && m.payload?.event?.kind === "state_changed")
    .map((m) => m.payload?.event?.state);

  // Look for assistant_message events
  const assistantMessages = wsMessages
    .filter((m) => m.dir === "in")
    .filter((m) => m.payload?.type === "event" && m.payload?.event?.kind === "assistant_message")
    .map((m) => m.payload?.event?.text || "");

  const hasParserHints =
    meta.title?.includes("parser") ||
    meta.title?.includes("state badge") ||
    meta.title?.includes("response") ||
    assistantMessages.some((t) => /\x1b\[/.test(t) || /^[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]/.test(t));

  return hasParserHints
    ? { stateChanges, assistantMessages }
    : null;
}

// ---------------------------------------------------------------------------
// Generate CCC fixture from parser failure
// ---------------------------------------------------------------------------

async function generateCccFixture(failure, parserInfo) {
  const num = await nextFixtureNumber();
  const slug = slugify(failure.meta.title || "playwright-capture");
  const fixtureName = `${num}-pw-${slug}`;
  const fixtureDir = path.join(CCC_FIXTURES_DIR, fixtureName);
  const framesDir = path.join(fixtureDir, "frames");

  await mkdir(framesDir, { recursive: true });

  // Build a synthetic frame from assistant messages captured
  const frameContent = parserInfo.assistantMessages.join("\n") || "(no content captured)";
  await writeFile(path.join(framesDir, "01.txt"), frameContent);

  // Build expected.json — mark as needing manual review
  const expected = {
    description: `Playwright capture: ${failure.meta.title}`,
    backend: "claude",
    _review: "NEEDS MANUAL REVIEW — generated from playwright failure. Update expected values.",
    detectReady: { isReady: true, confidence: "prompt" },
    extractLastResponse: frameContent.split("\n").filter((l) => l.trim()).pop() || "",
    detectPermission: null,
  };

  await writeFile(
    path.join(fixtureDir, "expected.json"),
    JSON.stringify(expected, null, 2),
  );

  return fixtureName;
}

// ---------------------------------------------------------------------------
// Main
// ---------------------------------------------------------------------------

async function main() {
  console.log("Scanning for Playwright failures...");
  const failures = await loadFailures();

  if (failures.length === 0) {
    console.log("No failures found. Nothing to generate.");
    return;
  }

  console.log(`Found ${failures.length} failure(s).`);

  // Build regression test file
  const regressionHeader = `/**
 * playwright-regressions.test.ts
 * AUTO-GENERATED by scripts/gen-test-from-failure.mjs — do not edit the header.
 * Each test is initially marked \`.skip\` — implement and remove skip once fixed.
 */
import { describe, it, expect } from "vitest";

describe("playwright regression cases", () => {`;

  const regressionFooter = `
});
`;

  const cases = failures.map(renderVitestCase);
  const regressionContent = regressionHeader + cases.join("\n") + regressionFooter;

  // Append to existing file or create new
  let existing = "";
  if (await exists(REGRESSION_FILE)) {
    existing = await readFile(REGRESSION_FILE, "utf8");
  }

  if (existing.includes("playwright regression cases")) {
    // File exists — append new cases before the closing brace
    const insertBefore = "\n});\n";
    const idx = existing.lastIndexOf(insertBefore);
    if (idx >= 0) {
      const updated = existing.slice(0, idx) + cases.join("\n") + existing.slice(idx);
      await writeFile(REGRESSION_FILE, updated);
    }
  } else {
    await writeFile(REGRESSION_FILE, regressionContent);
  }

  console.log(`\nWrote regression stubs → ${path.relative(SERVER_DIR, REGRESSION_FILE)}`);

  // Generate CCC fixtures for parser failures
  const parserFailures = failures
    .map((f) => {
      const info = detectParserFailure(f);
      return info ? { failure: f, info } : null;
    })
    .filter(Boolean);

  if (parserFailures.length > 0 && await exists(CCC_FIXTURES_DIR)) {
    for (const { failure, info } of parserFailures) {
      const fixtureName = await generateCccFixture(failure, info);
      console.log(`Created CCC fixture: tests/fixtures/${fixtureName}/`);
    }
    console.log("\nReview generated fixtures and update expected.json before running ccc tests.");
  }

  console.log("\nDone. Next steps:");
  console.log("  1. Review test/playwright-regressions.test.ts");
  console.log("  2. Implement each .skip test case");
  console.log("  3. Run: npm test -- test/playwright-regressions.test.ts");
  if (parserFailures.length > 0) {
    console.log("  4. Review CCC fixtures, update expected.json");
    console.log("  5. cd ../claude-code-connector && npm test -- tests/unit/ts/parser.fixtures.test.ts");
  }
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
