import http from "node:http";
import { WebSocket, WebSocketServer } from "ws";
import type { BridgeConfig } from "../config.js";
import type { Logger } from "../logger.js";
import { TokenBucketRateLimiter } from "../security/rate-limit.js";
import { readSystemStats } from "../system/stats.js";
import type { ApprovalAction, SessionBackend } from "../types/domain.js";
import type { RequestEnvelope } from "../types/protocol.js";
import { AuthService } from "./auth.js";
import { err, ok, safeJsonParse } from "./protocol.js";
import { validateRequest } from "./validators.js";
import type { SessionManager } from "../sessions/session-manager.js";
import type { InMemoryEventStore } from "../sessions/event-store.js";

type ConnectionState = "connected" | "authenticating" | "authenticated" | "closing";

export class WsGateway {
  private readonly wss: WebSocketServer;
  private activeSocket?: WebSocket;
  private readonly limiter = new TokenBucketRateLimiter(10, 30);

  constructor(
    server: http.Server,
    private readonly config: BridgeConfig,
    private readonly logger: Logger,
    private readonly auth: AuthService,
    private readonly sessions: SessionManager,
    events: InMemoryEventStore
  ) {
    this.wss = new WebSocketServer({
      server,
      maxPayload: config.maxWsMessageBytes
    });
    this.wss.on("connection", (socket, request) => {
      if (request.url && request.url !== "/" && request.url !== "/ws") {
        socket.close(1008, "unsupported path");
        return;
      }
      this.handleConnection(socket, request.socket.remoteAddress ?? "unknown");
    });
    events.subscribe((event) => {
      if (this.activeSocket?.readyState === WebSocket.OPEN) {
        this.activeSocket.send(JSON.stringify(event));
      }
    });
  }

  close() {
    this.wss.close();
  }

  private handleConnection(socket: WebSocket, remoteAddress: string) {
    let state: ConnectionState = "authenticating";
    let tokenVersionAtAuth: string | undefined;
    const authTimer = setTimeout(() => {
      if (state !== "authenticated") {
        state = "closing";
        socket.close(4001, "AUTH_TIMEOUT");
      }
    }, 5000);

    socket.on("message", async (data) => {
      if (Buffer.byteLength(data as Buffer) > this.config.maxWsMessageBytes) {
        socket.close(4013, "MESSAGE_TOO_LARGE");
        return;
      }
      const parsed = safeJsonParse(data.toString());
      const validation = validateRequest(parsed, this.config.maxPromptBytes);
      if (!validation.ok) {
        const requestId = typeof parsed === "object" && parsed && "id" in parsed ? String((parsed as { id: unknown }).id) : "unknown";
        if (validation.code === "UNSUPPORTED_PROTOCOL") socket.close(4004, "UNSUPPORTED_PROTOCOL");
        this.send(socket, err(requestId, validation.code, validation.message));
        return;
      }

      const request = validation.request;
      if (state !== "authenticated") {
        if (request.type !== "auth") {
          socket.close(4003, "AUTH_FAILED");
          return;
        }
        const result = this.auth.authenticate(request, remoteAddress);
        if (!result.ok) {
          socket.close(result.code === "RATE_LIMITED" ? 4008 : 4003, result.code);
          return;
        }
        clearTimeout(authTimer);
        state = "authenticated";
        tokenVersionAtAuth = this.auth.currentTokenVersion();
        this.replaceActiveSocket(socket);
        this.send(socket, ok(request.id, { authenticated: true, principal_id: result.principalId }));
        return;
      }

      if (tokenVersionAtAuth !== this.auth.currentTokenVersion()) {
        socket.close(4003, "TOKEN_ROTATED");
        return;
      }
      if (!this.limiter.allow(remoteAddress)) {
        this.send(socket, err(request.id, "RATE_LIMITED", "too many requests", true));
        return;
      }
      await this.handleRequest(socket, request);
    });

    socket.on("close", () => {
      state = "closing";
      clearTimeout(authTimer);
      if (this.activeSocket === socket) this.activeSocket = undefined;
    });

    socket.on("error", (error) => {
      this.logger.warn("ws_error", { message: error.message });
    });
  }

  private replaceActiveSocket(socket: WebSocket) {
    if (this.activeSocket && this.activeSocket !== socket) {
      this.activeSocket.close(4009, "CONNECTION_REPLACED");
    }
    this.activeSocket = socket;
  }

  private async handleRequest(socket: WebSocket, request: RequestEnvelope) {
    try {
      switch (request.type) {
        case "system.stats":
          this.send(socket, ok(request.id, await readSystemStats()));
          break;
        case "workspace.list":
          this.send(socket, ok(request.id, { workspaces: await this.sessions.listWorkspaces() }));
          break;
        case "workspace.create":
          this.send(socket, ok(request.id, { workspace: await this.sessions.createWorkspace(String(request.name)) }));
          break;
        case "session.list":
          this.send(socket, ok(request.id, { sessions: await this.sessions.list() }));
          break;
        case "session.run": {
          const session = await this.sessions.run({
            name: String(request.name),
            backend: normalizeBackend(request.backend),
            workspaceId: typeof request.workspace_id === "string" ? request.workspace_id : undefined,
            cwd: typeof request.cwd === "string" ? request.cwd : undefined
          });
          this.send(socket, ok(request.id, {
            session_id: session.sessionId,
            name: session.name,
            backend: session.backend,
            cwd: session.cwd,
            state: session.state,
            last_seq: session.lastSeq,
            needs_attention: session.state === "approval" || session.state === "choosing"
          }));
          break;
        }
        case "session.attach":
          this.send(socket, ok(request.id, await this.sessions.attach(String(request.session_id))));
          break;
        case "messages.list":
          this.send(socket, ok(request.id, await this.sessions.messages(
            String(request.session_id),
            Number.isInteger(request.before) ? Number(request.before) : undefined,
            Number.isInteger(request.limit) ? Number(request.limit) : undefined
          )));
          break;
        case "session.kill":
          this.send(socket, ok(request.id, await this.sessions.kill(String(request.session_id))));
          break;
        case "message.send":
          this.send(socket, ok(request.id, await this.sessions.sendMessage(
            String(request.session_id),
            String(request.client_msg_id),
            String(request.text)
          )));
          break;
        case "message.approve":
          this.send(socket, ok(request.id, await this.sessions.approve(
            String(request.session_id),
            String(request.approval_id),
            request.action as ApprovalAction,
            typeof request.idempotency_key === "string" ? request.idempotency_key : undefined
          )));
          break;
        case "message.interrupt":
          this.send(socket, ok(request.id, await this.sessions.interrupt(String(request.session_id))));
          break;
        case "command.send":
          this.send(socket, ok(request.id, await this.sessions.sendCommand(
            String(request.session_id),
            String(request.client_msg_id),
            String(request.command)
          )));
          break;
        case "file.resolve":
          this.send(socket, ok(request.id, await this.sessions.resolveFiles(
            String(request.session_id),
            Array.isArray(request.paths) ? request.paths.filter((item): item is string => typeof item === "string") : []
          )));
          break;
        case "file.read":
          this.send(socket, ok(request.id, await this.sessions.readFile(
            String(request.session_id),
            String(request.path)
          )));
          break;
        case "events.sync": {
          const after = Number(request.after ?? request.after_seq);
          const events = this.sessions.syncEvents(String(request.session_id), after);
          if (Array.isArray(events)) {
            const lastSeq = events.at(-1)?.seq ?? after;
            this.send(socket, ok(request.id, { events, last_seq: lastSeq }));
          } else {
            this.send(socket, err(request.id, "EVENT_GAP", "requested events are no longer available"));
          }
          break;
        }
        case "ping":
          this.send(socket, ok(request.id, { pong: true }));
          break;
        default:
          this.send(socket, err(request.id, "INVALID_REQUEST", "handler not implemented"));
      }
    } catch (error) {
      const message = error instanceof Error ? error.message : String(error);
      const code = normalizeErrorCode(message);
      this.send(socket, err(request.id, code, message, code === "CCC_TIMEOUT" || code === "CCC_COMMAND_FAILED"));
    }
  }

  private send(socket: WebSocket, payload: unknown) {
    if (socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(payload));
  }
}

function normalizeBackend(value: unknown): SessionBackend {
  if (value === "codex" || value === "opencode" || value === "cursor") return value;
  return "claude";
}

function normalizeErrorCode(message: string): string {
  const known = [
    "SESSION_NOT_FOUND",
    "SESSION_STATE_INVALID",
    "CCC_COMMAND_FAILED",
    "CCC_TIMEOUT",
    "APPROVAL_NOT_FOUND",
    "APPROVAL_EXPIRED",
    "EVENT_GAP",
    "FILE_NOT_FOUND",
    "RATE_LIMITED",
    "MESSAGE_TOO_LARGE",
    "PATH_NOT_ALLOWED",
    "WORKSPACE_INVALID",
    "SESSION_NAME_INVALID"
  ];
  return known.find((code) => message.includes(code)) ?? "INVALID_REQUEST";
}
