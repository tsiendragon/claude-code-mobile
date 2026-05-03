import { createHash } from "node:crypto";
import type { ApprovalAction, ApprovalRecord } from "../types/domain.js";
import type { CccReadResult, CccSession, CccTranscriptItem } from "./ccc-types.js";

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
      state: normalizeState(record.state),
      alive: typeof record.alive === "boolean" ? record.alive : undefined
    };
  });
}

export function parseCccRead(stdout: string): CccReadResult {
  const parsed = JSON.parse(stdout) as Record<string, unknown>;
  const output = parseReadOutput(parsed);
  const parsedItems = parseReadItems(parsed.lines);
  const items: CccTranscriptItem[] | undefined = parsedItems.length > 0
    ? parsedItems
    : output
      ? [{ id: "hist_1", role: "assistant", text: output }]
      : undefined;
  return {
    state: normalizeState(parsed.state) ?? "ready",
    output,
    items,
    pendingApproval: parsePendingApproval(parsed.pendingApproval ?? parsed.pending_approval)
  };
}

function parseReadOutput(parsed: Record<string, unknown>): string | undefined {
  if (typeof parsed.output === "string" && parsed.output.length > 0) return cleanAssistantResponseText(parsed.output);
  if (typeof parsed.lastResponse === "string" && parsed.lastResponse.length > 0) {
    return cleanAssistantResponseText(parsed.lastResponse);
  }
  if (typeof parsed.last_response === "string" && parsed.last_response.length > 0) {
    return cleanAssistantResponseText(parsed.last_response);
  }
  return undefined;
}

function parseReadItems(input: unknown): CccTranscriptItem[] {
  if (!Array.isArray(input)) return [];
  return parseTranscriptLines(input.filter((item): item is string => typeof item === "string"));
}

function parseTranscriptLines(lines: string[]): CccTranscriptItem[] {
  const items: CccTranscriptItem[] = [];
  let assistantBuffer: string[] = [];

  const addItem = (role: CccTranscriptItem["role"], text: string) => {
    const trimmed = text.trim();
    if (trimmed.length === 0) return;
    items.push({ id: `hist_${items.length + 1}`, role, text: trimmed });
  };

  const flushAssistant = () => {
    if (assistantBuffer.length === 0) return;
    addItem("assistant", cleanAssistantResponseText(assistantBuffer.join("\n")));
    assistantBuffer = [];
  };

  for (const rawLine of lines) {
    const line = cleanTerminalLine(rawLine);
    const trimmed = line.trim();

    const prompt = parsePromptLine(line);
    if (prompt !== undefined) {
      flushAssistant();
      addItem("user", prompt);
      continue;
    }

    if (trimmed.startsWith("●")) {
      flushAssistant();
      assistantBuffer = [stripAssistantMarker(trimmed)];
      continue;
    }

    if (assistantBuffer.length > 0) {
      if (isAssistantTerminator(trimmed)) {
        flushAssistant();
      } else if (!isTerminalChromeLine(trimmed)) {
        assistantBuffer.push(cleanAssistantContinuationLine(line));
      }
      continue;
    }
  }

  flushAssistant();
  return items;
}

function parsePromptLine(line: string): string | undefined {
  const match = line.match(/^\s*❯\s*(.*)$/u);
  if (!match) return undefined;
  const text = cleanTerminalLine(match[1]).trim();
  return text.length > 0 ? text : undefined;
}

function cleanAssistantResponseText(input: string): string {
  const cleaned: string[] = [];
  for (const rawLine of input.replace(/\r/g, "").split("\n")) {
    const line = cleanTerminalLine(rawLine);
    const trimmed = line.trim();
    if (isAssistantTerminator(trimmed)) continue;
    if (trimmed.startsWith("●")) {
      cleaned.push(stripAssistantMarker(trimmed));
    } else {
      cleaned.push(cleanAssistantContinuationLine(line));
    }
  }
  return trimBlankLines(cleaned).join("\n").replace(/\n{3,}/g, "\n\n");
}

function cleanTerminalLine(input: string): string {
  return stripAnsi(input)
    .replace(/\u00a0/g, " ")
    .replace(/[↓↑]/g, " ")
    .replace(/\s+$/g, "");
}

function cleanAssistantContinuationLine(line: string): string {
  return line.replace(/^\s{0,2}/, "").replace(/\s+$/g, "");
}

function stripAssistantMarker(line: string): string {
  return line
    .replace(/^●\s*/u, "")
    .replace(/^[\p{M}\p{Cf}\s]+/u, "")
    .replace(/\s+$/g, "");
}

function isAssistantTerminator(trimmedLine: string): boolean {
  return trimmedLine.startsWith("✻");
}

function isTerminalChromeLine(trimmedLine: string): boolean {
  if (trimmedLine.length === 0) return false;
  if (trimmedLine === "? for shortcuts") return true;
  if (/^[╭╮╰╯│─\s]+$/u.test(trimmedLine)) return true;
  return trimmedLine.startsWith("╭") ||
    trimmedLine.startsWith("╰") ||
    trimmedLine.startsWith("│") ||
    trimmedLine.startsWith("─");
}

function trimBlankLines(lines: string[]): string[] {
  let start = 0;
  let end = lines.length;
  while (start < end && lines[start].trim().length === 0) start++;
  while (end > start && lines[end - 1].trim().length === 0) end--;
  return lines.slice(start, end);
}

function stripAnsi(input: string): string {
  return input.replace(/\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])/g, "");
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
