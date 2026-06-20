import { createHash } from "node:crypto";
import { appendFile, mkdir, readFile } from "node:fs/promises";
import path from "node:path";
import type { CccReadResult } from "../ccc/ccc-types.js";

export type SnapshotArtifact = {
  capturedAt: string;
  rawStdout: string;
  parsed: CccReadResult;
  renderText: string;
};

/**
 * Holds the three badcase artifacts (raw ccc stdout, parsed read result,
 * rendered text) keyed by the transcript message_seq that produced them. The
 * raw stdout is discarded by applySnapshot once a message is persisted, so
 * artifacts are captured at generation time and looked up later when feedback
 * arrives.
 *
 * Backed by both an in-memory ring buffer (fast, bounded, FIFO-evicted) and an
 * optional on-disk JSONL mirror so artifacts survive a bridge restart — without
 * the disk mirror, every restart wiped the buffer and feedback on older
 * messages always reported artifacts_missing.
 */
export class SnapshotArchive {
  private readonly bySession = new Map<string, Map<number, SnapshotArtifact>>();

  constructor(
    private readonly perSessionLimit = 200,
    private readonly dataDir?: string
  ) {}

  record(cccName: string, messageSeq: number, artifact: SnapshotArtifact): void {
    let store = this.bySession.get(cccName);
    if (!store) {
      store = new Map();
      this.bySession.set(cccName, store);
    }
    // Re-insert so the newest entry sits at the tail for FIFO eviction.
    store.delete(messageSeq);
    store.set(messageSeq, artifact);
    while (store.size > this.perSessionLimit) {
      const oldest = store.keys().next().value;
      if (oldest === undefined) break;
      store.delete(oldest);
    }
    if (this.dataDir) {
      // Best-effort disk mirror; never block or break the snapshot flow.
      void this.persist(cccName, messageSeq, artifact).catch(() => undefined);
    }
  }

  /** Look up an artifact, falling back to the disk mirror after a restart. */
  async lookup(cccName: string, messageSeq: number): Promise<SnapshotArtifact | undefined> {
    const inMemory = this.bySession.get(cccName)?.get(messageSeq);
    if (inMemory) return inMemory;
    if (!this.dataDir) return undefined;
    return this.readFromDisk(cccName, messageSeq);
  }

  /** Synchronous, in-memory-only lookup (kept for existing callers/tests). */
  get(cccName: string, messageSeq: number): SnapshotArtifact | undefined {
    return this.bySession.get(cccName)?.get(messageSeq);
  }

  clear(cccName: string): void {
    this.bySession.delete(cccName);
  }

  private async persist(cccName: string, messageSeq: number, artifact: SnapshotArtifact): Promise<void> {
    await mkdir(this.snapshotDir(), { recursive: true });
    await appendFile(
      this.filePath(cccName),
      `${JSON.stringify({ message_seq: messageSeq, artifact })}\n`,
      "utf8"
    );
  }

  private async readFromDisk(cccName: string, messageSeq: number): Promise<SnapshotArtifact | undefined> {
    let body = "";
    try {
      body = await readFile(this.filePath(cccName), "utf8");
    } catch {
      return undefined;
    }
    // Walk newest-first so the latest capture for a seq wins.
    const lines = body.split("\n");
    for (let i = lines.length - 1; i >= 0; i -= 1) {
      const line = lines[i].trim();
      if (line.length === 0) continue;
      try {
        const parsed = JSON.parse(line) as { message_seq?: number; artifact?: SnapshotArtifact };
        if (parsed.message_seq === messageSeq && parsed.artifact) return parsed.artifact;
      } catch {
        continue;
      }
    }
    return undefined;
  }

  private snapshotDir(): string {
    return path.join(this.dataDir as string, "snapshots");
  }

  private filePath(cccName: string): string {
    const digest = createHash("sha256").update(cccName).digest("hex");
    return path.join(this.snapshotDir(), `${digest}.jsonl`);
  }
}
