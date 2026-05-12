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

  it("rejects large command replies", () => {
    const result = validateRequest({
      type: "command.send",
      id: "req_1",
      session_id: "sess_abcdefgh",
      client_msg_id: "cmsg_abcdef",
      command: "hello"
    }, 4);
    expect(result).toMatchObject({ ok: false, code: "MESSAGE_TOO_LARGE" });
  });

  it("accepts session.run with a workspace id", () => {
    expect(validateRequest({
      type: "session.run",
      id: "req_1",
      name: "Demo",
      backend: "codex",
      workspace_id: "demo-app"
    }, 1000).ok).toBe(true);
  });

  it("rejects unknown session backends", () => {
    const result = validateRequest({
      type: "session.run",
      id: "req_1",
      name: "Demo",
      backend: "unknown-agent",
      workspace_id: "demo-app"
    }, 1000);

    expect(result).toMatchObject({ ok: false, code: "INVALID_REQUEST" });
  });

  it("rejects ambiguous session.run targets", () => {
    const result = validateRequest({
      type: "session.run",
      id: "req_1",
      name: "Demo",
      workspace_id: "demo-app",
      cwd: "/tmp/demo-app"
    }, 1000);

    expect(result).toMatchObject({ ok: false, code: "INVALID_REQUEST" });
  });

  it("rejects empty or too-long session names", () => {
    expect(validateRequest({
      type: "session.run",
      id: "req_1",
      name: "   ",
      workspace_id: "demo-app"
    }, 1000)).toMatchObject({ ok: false, code: "INVALID_REQUEST" });

    expect(validateRequest({
      type: "session.run",
      id: "req_2",
      name: "a".repeat(81),
      workspace_id: "demo-app"
    }, 1000)).toMatchObject({ ok: false, code: "INVALID_REQUEST" });
  });

  it("accepts workspace.create", () => {
    expect(validateRequest({
      type: "workspace.create",
      id: "req_1",
      name: "demo-app"
    }, 1000).ok).toBe(true);
  });

  it("accepts system.stats without a session", () => {
    expect(validateRequest({
      type: "system.stats",
      id: "req_1"
    }, 1000).ok).toBe(true);
  });

  it("accepts file.resolve with session paths", () => {
    expect(validateRequest({
      type: "file.resolve",
      id: "req_1",
      session_id: "sess_abcdefgh",
      paths: ["report.md", "src/main.ts"]
    }, 1000).ok).toBe(true);
  });

  it("accepts file.read with a session path", () => {
    expect(validateRequest({
      type: "file.read",
      id: "req_1",
      session_id: "sess_abcdefgh",
      path: "report.md"
    }, 1000).ok).toBe(true);
  });

  it("accepts paginated message history requests", () => {
    expect(validateRequest({
      type: "messages.list",
      id: "req_1",
      session_id: "sess_abcdefgh",
      before: 42,
      limit: 50
    }, 1000).ok).toBe(true);
  });
});
