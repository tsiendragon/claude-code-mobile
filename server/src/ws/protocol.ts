import type { ResponseEnvelope } from "../types/protocol.js";

export function ok(id: string, data: unknown): ResponseEnvelope {
  return { type: "response", id, ok: true, data };
}

export function err(
  id: string,
  code: string,
  message: string,
  retryable = false
): ResponseEnvelope {
  return {
    type: "response",
    id,
    ok: false,
    error: { code, message, retryable }
  };
}

export function safeJsonParse(input: string): unknown {
  try {
    return JSON.parse(input);
  } catch {
    return undefined;
  }
}
