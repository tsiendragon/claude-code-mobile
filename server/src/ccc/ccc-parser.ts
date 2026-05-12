import { createHash } from "node:crypto";
import type { ApprovalAction, ApprovalRecord, SessionBackend } from "../types/domain.js";
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
      backend: normalizeBackend(record.backend ?? record.command),
      state: normalizeState(record.state),
      alive: typeof record.alive === "boolean" ? record.alive : undefined
    };
  });
}

export function parseCccRead(stdout: string): CccReadResult {
  const parsed = JSON.parse(stdout) as Record<string, unknown>;
  const output = parseReadOutput(parsed);
  const choicePrompt = parseChoicePrompt(parsed.lines, output);
  const parsedItems = parseReadItems(parsed.lines);
  const items: CccTranscriptItem[] | undefined = parsedItems.length > 0
    ? parsedItems
    : output
      ? [{ id: "hist_1", role: "assistant", text: output }]
      : undefined;
  const pendingApproval = parsePendingApproval(parsed.pendingApproval ?? parsed.pending_approval) ?? choicePrompt;
  return {
    state: pendingApproval?.operationKind === "choice"
      ? "choosing"
      : normalizeState(parsed.state) ?? "ready",
    output,
    items,
    pendingApproval
  };
}

export function parseCccHistory(stdout: string): CccTranscriptItem[] {
  const items: CccTranscriptItem[] = [];
  for (const line of stdout.split("\n")) {
    if (line.trim().length === 0) continue;
    let parsed: unknown;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    if (!parsed || typeof parsed !== "object") continue;
    const record = parsed as Record<string, unknown>;
    const role = normalizeTranscriptRole(record.role);
    const rawContent = typeof record.content === "string" ? record.content.trim() : "";
    const content = role === "assistant" ? cleanHistoryAssistantContent(rawContent) : rawContent;
    if (!role || content.length === 0) continue;
    if (role === "user" && isControlKeyHistoryEntry(content)) continue;
    items.push({
      id: `hist_${items.length + 1}`,
      role,
      text: content,
      createdAt: timestampToIso(record.ts),
      snapshot: record.event_type === "response"
    });
  }
  return items;
}

function isControlKeyHistoryEntry(content: string): boolean {
  return ["ENTER", "ESCAPE", "C-C", "CTRL-C"].includes(content.toUpperCase());
}

function parseReadOutput(parsed: Record<string, unknown>): string | undefined {
  if (typeof parsed.output === "string" && parsed.output.length > 0) {
    return cleanOptionalAssistantResponseText(parsed.output);
  }
  if (typeof parsed.lastResponse === "string" && parsed.lastResponse.length > 0) {
    return cleanOptionalAssistantResponseText(parsed.lastResponse);
  }
  if (typeof parsed.last_response === "string" && parsed.last_response.length > 0) {
    return cleanOptionalAssistantResponseText(parsed.last_response);
  }
  return undefined;
}

function parseReadItems(input: unknown): CccTranscriptItem[] {
  if (!Array.isArray(input)) return [];
  return parseTranscriptLines(input.filter((item): item is string => typeof item === "string"));
}

function parseChoicePrompt(linesInput: unknown, output: string | undefined): CccReadResult["pendingApproval"] {
  const lines = Array.isArray(linesInput)
    ? linesInput.filter((item): item is string => typeof item === "string")
    : output
      ? output.split("\n")
      : [];
  if (lines.length === 0) return undefined;

  const cleanedLines = lines.map((line) => cleanTerminalLine(line));
  const choices = [];
  for (const line of cleanedLines) {
    const match = line.match(/^\s*(?:[›>]\s*)?(\d{1,2})[.)]\s+(.+?)\s*$/u);
    if (!match) continue;
    const label = match[2].replace(/\s+/g, " ").trim();
    if (label.length === 0) continue;
    choices.push({ value: match[1], label });
  }
  if (choices.length < 2) return undefined;

  const meaningfulLines = cleanedLines
    .map((line) => line.trim())
    .filter((line) =>
      line.length > 0 &&
      !isTerminalChromeLine(line) &&
      !line.toLowerCase().startsWith("press enter") &&
      !line.startsWith("›")
    );
  const title = meaningfulLines.find((line) => !/^\d{1,2}[.)]\s+/.test(line)) ?? "Choose an option";
  const description = [
    title,
    "",
    ...choices.map((choice) => `${choice.value}. ${choice.label}`)
  ].join("\n");

  return {
    operationKind: "choice",
    description,
    paths: [],
    contentHash: createHash("sha256").update(JSON.stringify({ title, choices })).digest("hex"),
    actions: ["choice"],
    choices
  };
}

function normalizeTranscriptRole(input: unknown): CccTranscriptItem["role"] | undefined {
  return input === "user" || input === "assistant" ? input : undefined;
}

function timestampToIso(input: unknown): string | undefined {
  if (typeof input !== "number" || !Number.isFinite(input)) return undefined;
  const millis = input > 10_000_000_000 ? input : input * 1000;
  return new Date(millis).toISOString();
}

function cleanHistoryAssistantContent(input: string): string {
  const parsedItems = parseTranscriptLines(input.replace(/\r/g, "").split("\n"));
  const assistantText = parsedItems
    .filter((item) => item.role === "assistant")
    .map((item) => item.text)
    .filter((text) => text.length > 0)
    .join("\n\n");
  if (assistantText.length > 0) return assistantText;
  return cleanOptionalAssistantResponseText(input) ?? "";
}

function cleanOptionalAssistantResponseText(input: string): string | undefined {
  const cleaned = cleanAssistantResponseText(input);
  if (isTerminalChromeResponse(cleaned)) return undefined;
  return cleaned.length > 0 ? cleaned : undefined;
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

    if (isAssistantMarkerLine(trimmed)) {
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
    if (isAssistantMarkerLine(trimmed)) {
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
    .replace(/^[●⏺]\s*/u, "")
    .replace(/^[\p{M}\p{Cf}\s]+/u, "")
    .replace(/\s+$/g, "");
}

function isAssistantMarkerLine(trimmedLine: string): boolean {
  return trimmedLine.startsWith("●") || trimmedLine.startsWith("⏺");
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

function isTerminalChromeResponse(text: string): boolean {
  const trimmed = text.trim();
  if (trimmed.length === 0) return true;
  if (trimmed.includes("Welcome back") && trimmed.includes("Claude Code")) return true;
  if (/^Working \(\d+s/i.test(trimmed)) return true;
  if (/^Select model\b/i.test(trimmed)) return true;
  if (/^esc to interrupt$/i.test(trimmed)) return true;
  if (/^Enter to confirm\b/i.test(trimmed)) return true;
  return false;
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
  const choices = normalizeChoices(record.choices);
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
    actions,
    ...(choices.length > 0 ? { choices } : {})
  };
}

function normalizeChoices(value: unknown) {
  if (!Array.isArray(value)) return [];
  return value.flatMap((item) => {
    if (!item || typeof item !== "object") return [];
    const record = item as Record<string, unknown>;
    const choice = {
      value: String(record.value ?? "").trim(),
      label: String(record.label ?? "").trim()
    };
    return choice.value && choice.label ? [choice] : [];
  });
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

function normalizeBackend(value: unknown): SessionBackend | undefined {
  if (value === "claude" || value === "codex" || value === "opencode" || value === "cursor") {
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
