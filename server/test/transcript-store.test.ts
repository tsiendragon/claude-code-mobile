import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { TranscriptStore } from "../src/sessions/transcript-store.js";

describe("TranscriptStore", () => {
  it("persists messages and pages older history", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-transcripts-"));
    const store = new TranscriptStore(root);

    for (let index = 1; index <= 5; index += 1) {
      await store.append("demo-session", {
        role: index % 2 === 0 ? "assistant" : "user",
        text: `message ${index}`,
        created_at: `2026-01-01T00:00:0${index}.000Z`,
        source: "event"
      });
    }

    const latest = await store.list("demo-session", { limit: 2 });
    expect(latest).toMatchObject({
      has_more: true,
      next_before: 4,
      items: [
        { id: "msg_4", message_seq: 4, text: "message 4" },
        { id: "msg_5", message_seq: 5, text: "message 5" }
      ]
    });

    const older = await store.list("demo-session", { before: latest.next_before, limit: 2 });
    expect(older.items.map((item) => item.text)).toEqual(["message 2", "message 3"]);
  });

  it("imports connector history only when it is more complete", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-transcripts-"));
    const store = new TranscriptStore(root);

    await store.append("demo-session", { role: "user", text: "local prompt" });
    await expect(store.replaceIfLonger("demo-session", [
      { role: "user", text: "older prompt", source: "ccc_history" }
    ])).resolves.toBe(false);

    await expect(store.replaceIfLonger("demo-session", [
      { role: "user", text: "older prompt", source: "ccc_history" },
      { role: "assistant", text: "older response", source: "ccc_history" }
    ])).resolves.toBe(true);

    const latest = await store.list("demo-session");
    expect(latest.items.map((item) => item.text)).toEqual(["older prompt", "older response"]);
  });
});
