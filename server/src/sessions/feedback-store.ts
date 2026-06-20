import { createHash } from "node:crypto";
import { appendFile, mkdir } from "node:fs/promises";
import path from "node:path";
import type { FeedbackVerdict } from "../types/protocol.js";
import type { SnapshotArtifact } from "./snapshot-archive.js";

export type FeedbackArtifacts = {
  captured_at: string;
  raw_stdout: string;
  parsed: unknown;
  render_text: string;
};

export type FeedbackRecord = {
  feedback_id: string;
  created_at: string;
  session_id: string;
  ccc_name: string;
  backend: string;
  message_seq: number;
  message_id?: string;
  verdict: FeedbackVerdict;
  note?: string;
  artifacts_missing: boolean;
  artifacts?: FeedbackArtifacts;
  image_paths?: string[];
  client?: { app_version?: string; platform?: string };
};

/**
 * Appends one self-contained badcase record per line of JSONL. Each record
 * embeds the three artifacts so it can be replayed against the ccc parser
 * without the live session. Files are keyed by sha256(ccc_name) to avoid
 * leaking session names, mirroring TranscriptStore.
 */
export class FeedbackStore {
  constructor(private readonly dataDir: string) {}

  async append(cccName: string, record: FeedbackRecord): Promise<void> {
    await mkdir(this.feedbackDir(), { recursive: true });
    await appendFile(this.filePath(cccName), `${JSON.stringify(record)}\n`, "utf8");
  }

  private feedbackDir(): string {
    return path.join(this.dataDir, "feedback");
  }

  private filePath(cccName: string): string {
    const digest = createHash("sha256").update(cccName).digest("hex");
    return path.join(this.feedbackDir(), `${digest}.jsonl`);
  }
}

export function artifactsFromSnapshot(snapshot: SnapshotArtifact): FeedbackArtifacts {
  return {
    captured_at: snapshot.capturedAt,
    raw_stdout: snapshot.rawStdout,
    parsed: snapshot.parsed,
    render_text: snapshot.renderText
  };
}
