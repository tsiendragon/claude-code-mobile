import { mkdtemp, readdir, readFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { FeedbackStore, type FeedbackRecord } from "../src/sessions/feedback-store.js";

function record(overrides: Partial<FeedbackRecord> = {}): FeedbackRecord {
  return {
    feedback_id: "fb_test",
    created_at: "2026-06-13T00:00:00.000Z",
    session_id: "sess_abcdefgh",
    ccc_name: "ccm-demo",
    backend: "claude",
    message_seq: 1,
    verdict: "format_error",
    artifacts_missing: false,
    artifacts: {
      captured_at: "2026-06-13T00:00:00.000Z",
      raw_stdout: "{\"output\":\"hi\"}",
      parsed: { state: "ready", output: "hi" },
      render_text: "hi"
    },
    ...overrides
  };
}

describe("FeedbackStore", () => {
  it("appends badcase records as JSONL keyed by hashed ccc name", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-feedback-"));
    const store = new FeedbackStore(root);

    await store.append("ccm-demo", record());
    await store.append("ccm-demo", record({ feedback_id: "fb_two", verdict: "wrong_role" }));

    const dir = path.join(root, "feedback");
    const files = await readdir(dir);
    expect(files).toHaveLength(1);
    expect(files[0]).toMatch(/^[a-f0-9]{64}\.jsonl$/);

    const body = await readFile(path.join(dir, files[0]), "utf8");
    const lines = body.trim().split("\n").map((line) => JSON.parse(line) as FeedbackRecord);
    expect(lines).toHaveLength(2);
    expect(lines[0].verdict).toBe("format_error");
    expect(lines[0].artifacts?.raw_stdout).toContain("output");
    expect(lines[1].feedback_id).toBe("fb_two");
  });
});
