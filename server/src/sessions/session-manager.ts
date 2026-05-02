import { randomBytes, createHash } from "node:crypto";
import path from "node:path";
import type { BridgeConfig } from "../config.js";
import type { CccClient } from "../ccc/ccc-client.js";
import { assertAllowedCwd, isPathInside } from "../security/paths.js";
import type { ApprovalAction, ApprovalRecord, SessionRecord, SessionState } from "../types/domain.js";
import type { SessionSummary } from "../types/protocol.js";
import type { WorkspaceService } from "../workspaces/workspace-service.js";
import { InMemoryEventStore } from "./event-store.js";
import { canPerform, transitionState } from "./state-machine.js";

export type SessionRunInput = {
  name: string;
  cwd?: string;
  workspaceId?: string;
};

export class SessionManager {
  private readonly sessions = new Map<string, SessionRecord>();
  private readonly cccToBridge = new Map<string, string>();
  private readonly approvalResults = new Map<string, unknown>();
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
        if (!cccSession.cwd) continue;
        try {
          const realCwd = await assertAllowedCwd(cccSession.cwd, this.config.allowedPaths, {
            allowHiddenCwd: this.config.allowHiddenCwd
          });
          this.ensureSession(cccSession.name, realCwd, cccSession.state ?? "ready");
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
    const name = input.name;
    const cccName = `${name}-${randomBytes(4).toString("hex")}`;
    const result = await this.ccc.runSession(cccName, realCwd);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    return this.ensureSession(cccName, realCwd, "ready", name);
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
    return {
      session,
      last_seq: session.lastSeq,
      recent_events: Array.isArray(recent) ? recent : [],
      pending_approval: session.pendingApproval
    };
  }

  syncEvents(sessionId: string, afterSeq: number) {
    this.requireSession(sessionId);
    return this.events.listAfter(sessionId, afterSeq);
  }

  async kill(sessionId: string) {
    const session = this.requireSession(sessionId);
    if (!canPerform(session.state, "kill")) throw new Error("SESSION_STATE_INVALID");
    const result = await this.ccc.killSession(session.cccName);
    if (!result.ok) throw new Error(`${result.code}: ${result.message}`);
    this.updateState(session, "ended");
    this.events.clear(sessionId);
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
    if (!canPerform(session.state, "message.send", session.capabilities)) {
      throw new Error("SESSION_STATE_INVALID");
    }
    this.append(session, { kind: "user_message", clientMsgId, text: command, textBytes: Buffer.byteLength(command) });
    const result = await this.ccc.input(session.cccName, command);
    if (result.ok) {
      this.append(session, { kind: "message_delivered", clientMsgId });
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

  private ensureSession(cccName: string, cwd: string, state: SessionState, displayName = cccName): SessionRecord {
    const existingId = this.cccToBridge.get(cccName);
    if (existingId) {
      const existing = this.sessions.get(existingId);
      if (existing) {
        this.updateState(existing, state);
        return existing;
      }
    }
    const now = new Date().toISOString();
    const session: SessionRecord = {
      sessionId: `sess_${randomBytes(10).toString("base64url")}`,
      name: displayName,
      backend: "claude",
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
