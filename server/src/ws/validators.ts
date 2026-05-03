import { PROTOCOL_VERSION, type RequestEnvelope } from "../types/protocol.js";

const requestTypes = new Set([
  "auth",
  "ping",
  "workspace.list",
  "workspace.create",
  "session.list",
  "session.run",
  "session.attach",
  "session.kill",
  "message.send",
  "message.approve",
  "message.interrupt",
  "command.send",
  "events.sync"
]);

export type ValidationResult =
  | { ok: true; request: RequestEnvelope }
  | { ok: false; code: string; message: string };

export function validateRequest(input: unknown, maxPromptBytes: number): ValidationResult {
  if (!isObject(input)) return invalid("request must be an object");
  if (typeof input.type !== "string" || !requestTypes.has(input.type)) {
    return invalid("unknown request type");
  }
  if (typeof input.id !== "string" || input.id.length === 0) {
    return invalid("request id is required");
  }

  if (input.type === "auth") {
    if (input.protocol_version !== PROTOCOL_VERSION) {
      return { ok: false, code: "UNSUPPORTED_PROTOCOL", message: "protocol version unsupported" };
    }
    if (typeof input.token !== "string" && typeof input.authorization !== "string") {
      return invalid("auth token is required");
    }
  }

  if (requiresSession(input.type) && !isSessionId(input.session_id)) {
    return invalid("valid session_id is required");
  }

  if (input.type === "workspace.create") {
    if (typeof input.name !== "string" || input.name.trim().length === 0) {
      return invalid("workspace name is required");
    }
  }

  if (input.type === "session.run") {
    if (typeof input.name !== "string" || input.name.trim().length === 0) return invalid("name is required");
    if (input.name.trim().length > 80) return invalid("name must be 80 characters or fewer");
    const hasWorkspaceId = typeof input.workspace_id === "string" && input.workspace_id.length > 0;
    const hasCwd = typeof input.cwd === "string" && input.cwd.length > 0;
    if (hasWorkspaceId === hasCwd) return invalid("exactly one of workspace_id or cwd is required");
  }

  if (input.type === "message.send") {
    if (!isClientMessageId(input.client_msg_id)) return invalid("valid client_msg_id is required");
    if (typeof input.text !== "string") return invalid("text is required");
    if (Buffer.byteLength(input.text, "utf8") > maxPromptBytes) {
      return { ok: false, code: "MESSAGE_TOO_LARGE", message: "text exceeds max_prompt_bytes" };
    }
  }

  if (input.type === "command.send") {
    if (!isClientMessageId(input.client_msg_id)) return invalid("valid client_msg_id is required");
    if (typeof input.command !== "string" || input.command.length === 0) return invalid("command is required");
    if (Buffer.byteLength(input.command, "utf8") > maxPromptBytes) {
      return { ok: false, code: "MESSAGE_TOO_LARGE", message: "command exceeds max_prompt_bytes" };
    }
  }

  if (input.type === "message.approve") {
    if (typeof input.approval_id !== "string" || !input.approval_id.startsWith("appr_")) {
      return invalid("valid approval_id is required");
    }
    if (!["yes", "no", "approve", "reject", "always", "choice"].includes(String(input.action))) {
      return invalid("valid approval action is required");
    }
  }

  if (input.type === "events.sync") {
    const after = input.after ?? input.after_seq;
    if (!Number.isInteger(after) || Number(after) < 0) {
      return invalid("after must be a non-negative integer");
    }
  }

  return { ok: true, request: input as RequestEnvelope };
}

function invalid(message: string): ValidationResult {
  return { ok: false, code: "INVALID_REQUEST", message };
}

function isObject(input: unknown): input is Record<string, unknown> {
  return Boolean(input && typeof input === "object" && !Array.isArray(input));
}

function requiresSession(type: string): boolean {
  return [
    "session.attach",
    "session.kill",
    "message.send",
    "message.approve",
    "message.interrupt",
    "command.send",
    "events.sync"
  ].includes(type);
}

function isSessionId(value: unknown): boolean {
  return typeof value === "string" && /^sess_[a-zA-Z0-9_-]{8,}$/.test(value);
}

function isClientMessageId(value: unknown): boolean {
  return typeof value === "string" && /^(cmsg|msg)_[a-zA-Z0-9_-]{6,}$/.test(value);
}
