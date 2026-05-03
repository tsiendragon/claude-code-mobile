import { randomBytes, createHash } from "node:crypto";
import { open, realpath, stat } from "node:fs/promises";
import path from "node:path";
import type { BridgeConfig } from "../config.js";
import type { CccClient } from "../ccc/ccc-client.js";
import type { CccTranscriptItem } from "../ccc/ccc-types.js";
import { assertAllowedCwd, isPathInside } from "../security/paths.js";
import type { ApprovalAction, ApprovalRecord, SessionBackend, SessionRecord, SessionState } from "../types/domain.js";
import type { SessionSummary } from "../types/protocol.js";
import type { WorkspaceService } from "../workspaces/workspace-service.js";
import { InMemoryEventStore } from "./event-store.js";
import { canPerform, transitionState } from "./state-machine.js";

export type SessionRunInput = {
  name: string;
  backend?: SessionBackend;
  cwd?: string;
  workspaceId?: string;
};

export class SessionManager {
  private readonly sessions = new Map<string, SessionRecord>();
  private readonly cccToBridge = new Map<string, string>();
  private readonly approvalResults = new Map<string, unknown>();
  private readonly transcriptItems = new Map<string, CccTranscriptItem[]>();
  private poller?: { start(sessionId: string): void; stop(sessionId: string): void };

  constructor(
    private readonly config: BridgeConfig,
    private readonly ccc: CccClient,
    private readonly workspaces: WorkspaceService,
    private readonly events: InMemoryEventStore
  ) {}

  setPoller(poller: { start(sessionId: string): void; stop(sessionId: string): void }) {
    this.poller = poller;
  }

  async list(): Promise<SessionSummary[]> {
    const result = await this.ccc.listSessions();
    if (result.ok) {
      for (const cccSession of result.data) {
        if (cccSession.alive === false) continue;
        if (!cccSession.cwd) continue;
        try {
          const realCwd = await assertAllowedCwd(cccSession.cwd, this.config.allowedPaths, {
            allowHiddenCwd: this.config.allowHiddenCwd
          });
          this.ensureSession(cccSession.name, realCwd, cccSession.state ?? "ready", cccSession.name, cccSession.backend);
        } catch {
          continue;
        }
      }
    }
    return [...this.sessions.values()].map(toSummary);
  }

  async run(input: SessionRunInput): Promise<SessionRecord> {
    const realCwd = input.workspaceId
      ? await this.workspaces.resolveWorkspaceCwd(input.workspaceId)
      : await this.resolveManualCwd(input.cwd);
    const name = normalizeSessionDisplayName(input.name);
    const backend = input.backend ?? "claude";
    const cccName = buildCccName(name);
    const result = await this.ccc.runSession(cccName, realCwd, backend);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    return this.ensureSession(cccName, realCwd, "ready", name, backend);
  }

  listWorkspaces() {
    return this.workspaces.list();
  }

  createWorkspace(name: string) {
    return this.workspaces.create(name);
  }

  async attach(sessionId: string) {
    await this.applySnapshot(sessionId);
    const session = this.requireSession(sessionId);
    const recent = this.events.listAfter(sessionId, Math.max(0, session.lastSeq - this.config.eventBufferSize));
    const items = this.transcriptItems.get(sessionId);
    return {
      session,
      last_seq: session.lastSeq,
      ...(items && items.length > 0 ? { items } : {}),
      recent_events: Array.isArray(recent) ? recent : [],
      pending_approval: session.pendingApproval
    };
  }

  syncEvents(sessionId: string, afterSeq: number) {
    this.requireSession(sessionId);
    return this.events.listAfter(sessionId, afterSeq);
  }

  async readFile(sessionId: string, requestedPath: string) {
    const session = this.requireSession(sessionId);
    const realPath = await this.resolveSessionFilePath(session, requestedPath);
    const info = await stat(realPath);
    if (!info.isFile()) throw new Error("FILE_NOT_FOUND: path is not a file");

    const maxBytes = Math.max(1, this.config.maxEventBytes);
    const byteLength = Math.min(info.size, maxBytes);
    const buffer = Buffer.alloc(byteLength);
    const handle = await open(realPath, "r");
    try {
      await handle.read(buffer, 0, byteLength, 0);
    } finally {
      await handle.close();
    }

    const relativePath = path.relative(session.cwd, realPath);
    return {
      path: realPath,
      relative_path: relativePath,
      name: path.basename(realPath),
      bytes: info.size,
      truncated: info.size > byteLength,
      language: detectLanguage(realPath),
      content: buffer.toString("utf8")
    };
  }

  async kill(sessionId: string) {
    const session = this.requireSession(sessionId);
    if (!canPerform(session.state, "kill")) throw new Error("SESSION_STATE_INVALID");
    const result = await this.ccc.killSession(session.cccName);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    this.updateState(session, "ended");
    this.events.clear(sessionId);
    this.transcriptItems.delete(sessionId);
    this.poller?.stop(sessionId);
    return { killed: true };
  }

  async sendMessage(sessionId: string, clientMsgId: string, text: string) {
    const session = this.requireSession(sessionId);
    if (!canPerform(session.state, "message.send", session.capabilities)) {
      throw new Error("SESSION_STATE_INVALID");
    }
    this.append(session, { kind: "user_message", clientMsgId, text, textBytes: Buffer.byteLength(text) });
    const result = await this.ccc.sendMessage(session.cccName, text);
    if (result.ok) {
      this.append(session, { kind: "message_delivered", clientMsgId });
      this.updateState(session, "thinking");
      return { delivered: true };
    }
    this.append(session, {
      kind: "message_failed",
      clientMsgId,
      code: result.code,
      message: result.message
    });
    throw new Error(`${result.code}: ${result.message}`);
  }

  async approve(sessionId: string, approvalId: string, action: ApprovalAction, idempotencyKey?: string) {
    const session = this.requireSession(sessionId);
    const idempotencyMapKey = idempotencyKey ? `${sessionId}:${idempotencyKey}` : undefined;
    if (idempotencyMapKey && this.approvalResults.has(idempotencyMapKey)) {
      return this.approvalResults.get(idempotencyMapKey);
    }
    if (!canPerform(session.state, "approve", session.capabilities)) throw new Error("SESSION_STATE_INVALID");
    const pending = session.pendingApproval;
    if (!pending || pending.approvalId !== approvalId) throw new Error("APPROVAL_NOT_FOUND");
    if (new Date(pending.expiresAt).getTime() <= Date.now()) throw new Error("APPROVAL_EXPIRED");
    this.assertApprovalPathsInSession(session, pending);
    const cccAction = normalizeApprovalAction(action);
    const result = await this.ccc.approve(session.cccName, cccAction);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    pending.status = cccAction === "no" ? "rejected" : "approved";
    this.append(session, { kind: "approval_resolved", approvalId, status: pending.status });
    session.pendingApproval = undefined;
    this.updateState(session, "thinking");
    const response = { approved: pending.status === "approved", status: pending.status };
    if (idempotencyMapKey) this.approvalResults.set(idempotencyMapKey, response);
    return response;
  }

  async sendCommand(sessionId: string, clientMsgId: string, command: string) {
    const session = this.requireSession(sessionId);
    if (!canPerform(session.state, "command.send", session.capabilities)) {
      throw new Error("SESSION_STATE_INVALID");
    }
    this.append(session, { kind: "user_message", clientMsgId, text: command, textBytes: Buffer.byteLength(command) });
    const inputResult = await this.ccc.input(session.cccName, command);
    const result = inputResult.ok ? await this.ccc.key(session.cccName, "Enter") : inputResult;
    if (result.ok) {
      this.append(session, { kind: "message_delivered", clientMsgId });
      this.updateState(session, "thinking");
      return { delivered: true };
    }
    this.append(session, {
      kind: "message_failed",
      clientMsgId,
      code: result.code,
      message: result.message
    });
    throw new Error(`${result.code}: ${result.message}`);
  }

  async interrupt(sessionId: string) {
    const session = this.requireSession(sessionId);
    if (!canPerform(session.state, "interrupt", session.capabilities)) throw new Error("SESSION_STATE_INVALID");
    const result = await this.ccc.interrupt(session.cccName);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    if (session.pendingApproval) {
      session.pendingApproval.status = "interrupted";
      this.append(session, {
        kind: "approval_resolved",
        approvalId: session.pendingApproval.approvalId,
        status: "interrupted"
      });
      session.pendingApproval = undefined;
    }
    this.updateState(session, "ready");
    return { interrupted: true };
  }

  async applySnapshot(sessionId: string) {
    const session = this.requireSession(sessionId);
    const result = await this.ccc.read(session.cccName);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    this.updateState(session, result.data.state);
    if (result.data.items && result.data.items.length > 0) {
      this.transcriptItems.set(sessionId, result.data.items);
    }
    if (result.data.output) {
      const hash = createHash("sha256").update(normalizeSnapshot(result.data.output)).digest("hex");
      if (hash !== session.lastSnapshotHash) {
        session.lastSnapshotHash = hash;
        this.append(session, { kind: "assistant_message", text: result.data.output, snapshot: true });
      }
    }
    if (result.data.pendingApproval) {
      const existing = session.pendingApproval;
      if (!existing || existing.contentHash !== result.data.pendingApproval.contentHash) {
        session.pendingApproval = createApproval(session.sessionId, result.data.pendingApproval);
        this.append(session, { kind: "approval_requested", approval: session.pendingApproval });
      }
    } else if (session.pendingApproval?.status === "pending" && session.state !== "approval" && session.state !== "choosing") {
      session.pendingApproval = undefined;
    }
    return session;
  }

  requireSession(sessionId: string): SessionRecord {
    const session = this.sessions.get(sessionId);
    if (!session) throw new Error("SESSION_NOT_FOUND");
    return session;
  }

  private ensureSession(
    cccName: string,
    cwd: string,
    state: SessionState,
    displayName = cccName,
    backend: SessionBackend = "claude"
  ): SessionRecord {
    const existingId = this.cccToBridge.get(cccName);
    if (existingId) {
      const existing = this.sessions.get(existingId);
      if (existing) {
        this.updateState(existing, state);
        existing.backend = backend;
        return existing;
      }
    }
    const now = new Date().toISOString();
    const session: SessionRecord = {
      sessionId: `sess_${randomBytes(10).toString("base64url")}`,
      name: displayName,
      backend,
      cwd,
      cccName,
      state,
      createdAt: now,
      updatedAt: now,
      lastSeq: 0,
      capabilities: {
        canSendWhenThinking: false,
        canSendWhenError: false,
        canInterrupt: true,
        canApprove: true
      }
    };
    this.sessions.set(session.sessionId, session);
    this.cccToBridge.set(cccName, session.sessionId);
    this.poller?.start(session.sessionId);
    return session;
  }

  private updateState(session: SessionRecord, next: SessionState) {
    const previous = session.state;
    session.state = transitionState(session.state, next);
    session.updatedAt = new Date().toISOString();
    if (session.state !== previous) {
      this.append(session, { kind: "state_changed", state: session.state, previousState: previous });
    }
  }

  private append(session: SessionRecord, event: Parameters<InMemoryEventStore["append"]>[1]) {
    const stored = this.events.append(session.sessionId, event);
    session.lastSeq = stored.seq;
    session.updatedAt = stored.created_at;
    return stored;
  }

  private async resolveManualCwd(cwd: string | undefined): Promise<string> {
    if (!this.config.allowManualCwd) {
      throw new Error("PATH_NOT_ALLOWED: manual cwd is disabled");
    }
    if (!cwd) {
      throw new Error("PATH_NOT_ALLOWED: cwd is required");
    }
    return assertAllowedCwd(cwd, this.config.allowedPaths, {
      allowHiddenCwd: this.config.allowHiddenCwd
    });
  }

  private async resolveSessionFilePath(session: SessionRecord, requestedPath: string): Promise<string> {
    const trimmed = requestedPath.trim();
    if (trimmed.length === 0 || trimmed.includes("\0")) {
      throw new Error("PATH_NOT_ALLOWED: file path is required");
    }
    const candidate = path.isAbsolute(trimmed)
      ? path.resolve(trimmed)
      : path.resolve(session.cwd, trimmed);
    let realPath: string;
    try {
      realPath = await realpath(candidate);
    } catch {
      throw new Error("FILE_NOT_FOUND: file does not exist");
    }
    if (!isPathInside(realPath, session.cwd)) {
      throw new Error("PATH_NOT_ALLOWED: file is outside session cwd");
    }
    return realPath;
  }

  private assertApprovalPathsInSession(session: SessionRecord, approval: ApprovalRecord) {
    for (const rawPath of approval.paths) {
      if (rawPath.trim().length === 0) continue;
      const candidate = path.isAbsolute(rawPath)
        ? path.resolve(rawPath)
        : path.resolve(session.cwd, rawPath);
      if (!isPathInside(candidate, session.cwd)) {
        throw new Error("PATH_NOT_ALLOWED: approval path is outside session cwd");
      }
    }
  }
}

function toSummary(session: SessionRecord): SessionSummary {
  return {
    session_id: session.sessionId,
    name: session.name,
    backend: session.backend,
    cwd: session.cwd,
    state: session.state,
    last_seq: session.lastSeq,
    needs_attention: session.state === "approval" || session.state === "choosing"
  };
}

function normalizeSnapshot(output: string): string {
  return output.replace(/\r/g, "").replace(/\d{1,2}:\d{2}:\d{2}/g, "<time>");
}

function createApproval(
  sessionId: string,
  pending: Omit<ApprovalRecord, "approvalId" | "sessionId" | "expiresAt" | "status">
): ApprovalRecord {
  return {
    ...pending,
    approvalId: `appr_${randomBytes(10).toString("base64url")}`,
    sessionId,
    expiresAt: new Date(Date.now() + 10 * 60 * 1000).toISOString(),
    status: "pending"
  };
}

function normalizeApprovalAction(action: ApprovalAction): "yes" | "no" | "always" | "choice" {
  if (action === "approve") return "yes";
  if (action === "reject") return "no";
  return action;
}

function normalizeSessionDisplayName(input: string): string {
  const name = input.trim().replace(/\s+/g, " ");
  if (name.length === 0 || name.length > 80) {
    throw new Error("SESSION_NAME_INVALID: session name must be 1-80 characters");
  }
  return name;
}

function buildCccName(displayName: string): string {
  const slug = displayName
    .toLowerCase()
    .replace(/[^a-z0-9_-]+/g, "-")
    .replace(/^-+|-+$/g, "")
    .slice(0, 48);
  return `${slug || "session"}-${randomBytes(4).toString("hex")}`;
}

function detectLanguage(filePath: string): string {
  const base = path.basename(filePath).toLowerCase();
  if (base === "dockerfile") return "dockerfile";
  if (base === "makefile") return "makefile";
  const ext = path.extname(base).replace(/^\./, "");
  const languages: Record<string, string> = {
    bash: "shell",
    c: "c",
    cc: "cpp",
    cjs: "javascript",
    cpp: "cpp",
    cs: "csharp",
    css: "css",
    csv: "csv",
    dart: "dart",
    env: "dotenv",
    go: "go",
    gradle: "gradle",
    h: "c",
    hpp: "cpp",
    html: "html",
    java: "java",
    js: "javascript",
    json: "json",
    jsx: "jsx",
    kt: "kotlin",
    lock: "text",
    lua: "lua",
    m: "objective-c",
    markdown: "markdown",
    md: "markdown",
    mjs: "javascript",
    php: "php",
    py: "python",
    r: "r",
    rb: "ruby",
    rs: "rust",
    scss: "scss",
    sh: "shell",
    sql: "sql",
    swift: "swift",
    toml: "toml",
    ts: "typescript",
    tsx: "tsx",
    txt: "text",
    xml: "xml",
    yaml: "yaml",
    yml: "yaml",
    zsh: "shell"
  };
  return languages[ext] ?? ext ?? "text";
}
