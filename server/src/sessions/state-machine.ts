import type { SessionState } from "../types/domain.js";

export type SessionOperation = "message.send" | "command.send" | "approve" | "interrupt" | "kill";

export function canPerform(
  state: SessionState,
  operation: SessionOperation,
  capabilities = { canSendWhenThinking: false, canSendWhenError: false }
): boolean {
  if (state === "ended") return false;
  if (operation === "kill") return true;
  if (operation === "interrupt") return ["thinking", "approval", "choosing", "error"].includes(state);
  if (operation === "approve") return state === "approval" || state === "choosing";
  if (operation === "message.send") {
    if (state === "ready") return true;
    if (state === "thinking") return capabilities.canSendWhenThinking;
    if (state === "error") return capabilities.canSendWhenError;
  }
  if (operation === "command.send") {
    return state === "ready" || state === "approval" || state === "choosing";
  }
  return false;
}

export function transitionState(current: SessionState, next: SessionState): SessionState {
  if (current === "ended") return "ended";
  return next;
}
