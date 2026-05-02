import { describe, expect, it } from "vitest";
import { canPerform } from "../src/sessions/state-machine.js";

describe("state machine", () => {
  it("enforces MVP operation matrix", () => {
    expect(canPerform("ready", "message.send")).toBe(true);
    expect(canPerform("thinking", "message.send")).toBe(false);
    expect(canPerform("thinking", "message.send", { canSendWhenThinking: true, canSendWhenError: false })).toBe(true);
    expect(canPerform("approval", "approve")).toBe(true);
    expect(canPerform("ended", "kill")).toBe(false);
  });
});
