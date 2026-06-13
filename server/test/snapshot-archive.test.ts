import { describe, expect, it } from "vitest";
import { SnapshotArchive } from "../src/sessions/snapshot-archive.js";
import type { CccReadResult } from "../src/ccc/ccc-types.js";

function artifact(text: string) {
  return {
    capturedAt: "2026-06-13T00:00:00.000Z",
    rawStdout: `{"output":"${text}"}`,
    parsed: { state: "ready", output: text } as CccReadResult,
    renderText: text
  };
}

describe("SnapshotArchive", () => {
  it("records and retrieves artifacts by message seq", () => {
    const archive = new SnapshotArchive();
    archive.record("demo", 3, artifact("hello"));
    expect(archive.get("demo", 3)?.renderText).toBe("hello");
    expect(archive.get("demo", 4)).toBeUndefined();
    expect(archive.get("other", 3)).toBeUndefined();
  });

  it("evicts oldest entries beyond the per-session limit", () => {
    const archive = new SnapshotArchive(2);
    archive.record("demo", 1, artifact("one"));
    archive.record("demo", 2, artifact("two"));
    archive.record("demo", 3, artifact("three"));
    expect(archive.get("demo", 1)).toBeUndefined();
    expect(archive.get("demo", 2)?.renderText).toBe("two");
    expect(archive.get("demo", 3)?.renderText).toBe("three");
  });
});
