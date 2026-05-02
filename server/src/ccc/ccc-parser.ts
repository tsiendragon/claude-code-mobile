import { createHash } from "node:crypto";
import type { ApprovalAction, ApprovalRecord } from "../types/domain.js";
import type { CccReadResult, CccSession } from "./ccc-types.js";

export function parseCccSessionList(stdout: string): CccSession[] {
  const parsed = JSON.parse(stdout) as unknown;
  const sessions = Array.isArray(parsed) ? parsed : getArrayProperty(parsed, "sessions");
  return sessions.map((item) => {
    if (!item || typeof item !== "object") throw new Error("invalid ccc session item");
    const record = item as Record<string, unknown>;
    if (typeof record.name !== "string") throw new Error("ccc session missing name");
    return {
      name: record.name,
      cwd: typeof record.cwd === "string" ? record.cwd : undefined,
      state: normalizeState(record.state)
    };
  });
}

export function parseCccRead(stdout: string): CccReadResult {
  const parsed = JSON.parse(stdout) as Record<string, unknown>;
  return {
    state: normalizeState(parsed.state) ?? "ready",
    output: typeof parsed.output === "string" ? parsed.output : undefined,
    pendingApproval: parsePendingApproval(parsed.pendingApproval ?? parsed.pending_approval)
  };
}

function parsePendingApproval(input: unknown): CccReadResult["pendingApproval"] {
  if (!input || typeof input !== "object") return undefined;
  const record = input as Record<string, unknown>;
  const operationKind = normalizeOperationKind(record.operationKind ?? record.operation_kind);
  const description = typeof record.description === "string" ? record.description : "Approval requested";
  const paths = Array.isArray(record.paths) ? record.paths.filter((item): item is string => typeof item === "string") : [];
  const actions = normalizeActions(record.actions);
  const diffSummary = typeof record.diffSummary === "string"
    ? record.diffSummary
    : typeof record.diff_summary === "string"
      ? record.diff_summary
      : undefined;
  const contentHash = typeof record.contentHash === "string"
    ? record.contentHash
    : createHash("sha256").update(JSON.stringify({ operationKind, description, paths, diffSummary, actions })).digest("hex");
  return {
    operationKind,
    description,
    paths,
    diffSummary,
    contentHash,
    actions
  };
}

function getArrayProperty(input: unknown, property: string): unknown[] {
  if (!input || typeof input !== "object") throw new Error("invalid ccc json");
  const value = (input as Record<string, unknown>)[property];
  if (!Array.isArray(value)) throw new Error(`ccc json missing ${property}`);
  return value;
}

function normalizeState(value: unknown) {
  if (
    value === "ready" ||
    value === "thinking" ||
    value === "approval" ||
    value === "choosing" ||
    value === "error" ||
    value === "ended"
  ) {
    return value;
  }
  return undefined;
}

function normalizeOperationKind(value: unknown): ApprovalRecord["operationKind"] {
  if (value === "file_edit" || value === "command" || value === "choice" || value === "unknown") {
    return value;
  }
  return "unknown";
}

function normalizeActions(value: unknown): ApprovalAction[] {
  if (!Array.isArray(value)) return ["yes", "no"];
  const actions = value.filter((item): item is ApprovalAction =>
    item === "yes" ||
    item === "no" ||
    item === "approve" ||
    item === "reject" ||
    item === "always" ||
    item === "choice"
  );
  return actions.length > 0 ? actions : ["yes", "no"];
}
