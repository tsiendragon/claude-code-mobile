import { describe, expect, it } from "vitest";
import { validateRequest } from "../src/ws/validators.js";

describe("protocol validators", () => {
  it("accepts auth with supported protocol", () => {
    expect(validateRequest({
      type: "auth",
      id: "req_1",
      token: "x".repeat(32),
      protocol_version: 1
    }, 1000).ok).toBe(true);
  });

  it("rejects large prompts", () => {
    const result = validateRequest({
      type: "message.send",
      id: "req_1",
      session_id: "sess_abcdefgh",
      client_msg_id: "cmsg_abcdef",
      text: "hello"
    }, 4);
    expect(result).toMatchObject({ ok: false, code: "MESSAGE_TOO_LARGE" });
  });
});
