import { createHash } from "node:crypto";
import { appendFile, mkdir, readFile, rename, writeFile } from "node:fs/promises";
import path from "node:path";

export type TranscriptRole = "user" | "assistant" | "system";

export type TranscriptMessage = {
  id: string;
  message_seq: number;
  role: TranscriptRole;
  text: string;
  created_at: string;
  snapshot?: boolean;
  source?: "event" | "ccc_history" | "ccc_read";
};

export type TranscriptInput = {
  role: TranscriptRole;
  text: string;
  created_at?: string;
  snapshot?: boolean;
  source?: TranscriptMessage["source"];
};

export type TranscriptPage = {
  items: TranscriptMessage[];
  has_more: boolean;
  next_before?: number;
};

export class TranscriptStore {
  private readonly lastSeq = new Map<string, number>();

  constructor(private readonly dataDir: string) {}

  async appendIfNewTail(cccName: string, input: TranscriptInput): Promise<{ message: TranscriptMessage; created: boolean }> {
    const text = input.text.trim();
    if (text.length === 0) throw new Error("TRANSCRIPT_EMPTY");
    const latest = await this.list(cccName, { limit: 1 });
    const tail = latest.items.at(-1);
    if (tail && tail.role === input.role && normalizeText(tail.text) === normalizeText(text)) {
      return { message: tail, created: false };
    }
    const message = await this.append(cccName, { ...input, text });
    return { message, created: true };
  }

  async append(cccName: string, input: TranscriptInput): Promise<TranscriptMessage> {
    const text = input.text.trim();
    if (text.length === 0) throw new Error("TRANSCRIPT_EMPTY");
    const seq = await this.nextSeq(cccName);
    const message: TranscriptMessage = {
      id: `msg_${seq}`,
      message_seq: seq,
      role: input.role,
      text,
      created_at: input.created_at ?? new Date().toISOString(),
      ...(input.snapshot === undefined ? {} : { snapshot: input.snapshot }),
      ...(input.source === undefined ? {} : { source: input.source })
    };
    await mkdir(this.transcriptDir(), { recursive: true });
    await appendFile(this.filePath(cccName), `${JSON.stringify(message)}\n`, "utf8");
    return message;
  }

  async replaceIfLonger(cccName: string, inputs: TranscriptInput[]): Promise<boolean> {
    const normalized = inputs
      .map((input) => ({
        ...input,
        text: input.text.trim()
      }))
      .filter((input) => input.text.length > 0);
    if (normalized.length === 0) return false;
    const existing = await this.readAll(cccName);
    if (normalized.length <= existing.length && !hasImportedTerminalChrome(existing)) return false;

    const messages = normalized.map((input, index): TranscriptMessage => {
      const seq = index + 1;
      return {
        id: `msg_${seq}`,
        message_seq: seq,
        role: input.role,
        text: input.text,
        created_at: input.created_at ?? new Date().toISOString(),
        ...(input.snapshot === undefined ? {} : { snapshot: input.snapshot }),
        ...(input.source === undefined ? {} : { source: input.source })
      };
    });
    await this.writeAll(cccName, messages);
    this.lastSeq.set(cccName, messages.at(-1)?.message_seq ?? 0);
    return true;
  }

  async list(cccName: string, options: { before?: number; limit?: number } = {}): Promise<TranscriptPage> {
    const limit = clampLimit(options.limit);
    const before = options.before;
    const all = await this.readAll(cccName);
    const eligible = before === undefined ? all : all.filter((item) => item.message_seq < before);
    const start = Math.max(0, eligible.length - limit);
    const items = eligible.slice(start);
    const hasMore = start > 0;
    return {
      items,
      has_more: hasMore,
      ...(hasMore && items.length > 0 ? { next_before: items[0].message_seq } : {})
    };
  }

  private async nextSeq(cccName: string): Promise<number> {
    const cached = this.lastSeq.get(cccName);
    if (cached !== undefined) {
      const next = cached + 1;
      this.lastSeq.set(cccName, next);
      return next;
    }
    const all = await this.readAll(cccName);
    const next = (all.at(-1)?.message_seq ?? 0) + 1;
    this.lastSeq.set(cccName, next);
    return next;
  }

  private async readAll(cccName: string): Promise<TranscriptMessage[]> {
    let body = "";
    try {
      body = await readFile(this.filePath(cccName), "utf8");
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") return [];
      throw error;
    }

    const messages: TranscriptMessage[] = [];
    for (const line of body.split("\n")) {
      if (line.trim().length === 0) continue;
      const parsed = JSON.parse(line) as unknown;
      if (!isTranscriptMessage(parsed)) continue;
      messages.push(parsed);
    }
    if (messages.length > 0) {
      this.lastSeq.set(cccName, messages.at(-1)?.message_seq ?? 0);
    }
    return messages;
  }

  private async writeAll(cccName: string, messages: TranscriptMessage[]): Promise<void> {
    await mkdir(this.transcriptDir(), { recursive: true });
    const file = this.filePath(cccName);
    const temp = `${file}.${process.pid}.${Date.now()}.tmp`;
    const body = messages.map((message) => JSON.stringify(message)).join("\n");
    await writeFile(temp, body.length > 0 ? `${body}\n` : "", "utf8");
    await rename(temp, file);
  }

  private transcriptDir(): string {
    return path.join(this.dataDir, "transcripts");
  }

  private filePath(cccName: string): string {
    const digest = createHash("sha256").update(cccName).digest("hex");
    return path.join(this.transcriptDir(), `${digest}.jsonl`);
  }
}

function clampLimit(limit: number | undefined): number {
  if (!Number.isInteger(limit)) return 50;
  return Math.min(200, Math.max(1, Number(limit)));
}

function normalizeText(text: string): string {
  return text.replace(/\r/g, "").replace(/\s+$/gm, "").trim();
}

function hasImportedTerminalChrome(messages: TranscriptMessage[]): boolean {
  return messages.some((message) =>
    (message.source === "ccc_history" || message.source === "ccc_read") &&
    looksLikeTerminalChrome(message.text)
  );
}

function looksLikeTerminalChrome(text: string): boolean {
  return (text.includes("Welcome back") && text.includes("Claude Code")) ||
    text.includes("Tips for getting started") ||
    text.includes("❯ ") ||
    /^Working \(\d+s/i.test(text.trim());
}

function isTranscriptMessage(input: unknown): input is TranscriptMessage {
  if (!input || typeof input !== "object") return false;
  const record = input as Record<string, unknown>;
  return typeof record.id === "string" &&
    typeof record.message_seq === "number" &&
    (record.role === "user" || record.role === "assistant" || record.role === "system") &&
    typeof record.text === "string" &&
    typeof record.created_at === "string";
}
