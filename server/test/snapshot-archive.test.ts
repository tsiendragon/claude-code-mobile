import { mkdtemp } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
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

  it("survives a restart via the on-disk mirror", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-snap-"));
    const archive = new SnapshotArchive(200, dir);
    archive.record("demo", 7, artifact("persist me"));
    // allow the best-effort async disk write to land
    await new Promise((resolve) => setTimeout(resolve, 50));

    // a fresh instance (as after a bridge restart) has empty memory
    const restarted = new SnapshotArchive(200, dir);
    expect(restarted.get("demo", 7)).toBeUndefined();
    expect((await restarted.lookup("demo", 7))?.renderText).toBe("persist me");
    expect(await restarted.lookup("demo", 8)).toBeUndefined();
  });
});
