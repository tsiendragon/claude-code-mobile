import type { CccReadResult } from "../ccc/ccc-types.js";

export type SnapshotArtifact = {
  capturedAt: string;
  rawStdout: string;
  parsed: CccReadResult;
  renderText: string;
};

/**
 * In-memory ring buffer holding the three badcase artifacts (raw ccc stdout,
 * parsed read result, rendered text) keyed by the transcript message_seq that
 * they produced. The raw stdout is discarded by applySnapshot once a message is
 * persisted, so artifacts must be captured at generation time; feedback arriving
 * later looks them back up here by seq. Capacity is bounded per ccc session and
 * evicted FIFO so the buffer never grows unbounded.
 */
export class SnapshotArchive {
  private readonly bySession = new Map<string, Map<number, SnapshotArtifact>>();

  constructor(private readonly perSessionLimit = 200) {}

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
  }

  get(cccName: string, messageSeq: number): SnapshotArtifact | undefined {
    return this.bySession.get(cccName)?.get(messageSeq);
  }

  clear(cccName: string): void {
    this.bySession.delete(cccName);
  }
}
