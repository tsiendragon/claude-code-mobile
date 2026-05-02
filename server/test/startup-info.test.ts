import { describe, expect, it } from "vitest";
import type { BridgeConfig } from "../src/config.js";
import { buildStartupInfo } from "../src/startup-info.js";

function config(overrides: Partial<BridgeConfig> = {}): BridgeConfig {
  return {
    host: "127.0.0.1",
    port: 8900,
    tokenEnv: "CCM_TOKEN",
    tokenSource: "env",
    token: "x".repeat(32),
    allowedPaths: ["/home/user/workspace"],
    workspaceRoot: "/home/user/workspace",
    allowManualCwd: true,
    cccBin: "ccc",
    pollIntervalMs: 1000,
    eventBufferSize: 200,
    maxPromptBytes: 102400,
    maxWsMessageBytes: 262144,
    maxEventBytes: 524288,
    allowWideBind: false,
    allowHiddenCwd: false,
    logLevel: "info",
    cccTimeoutMs: 15000,
    ...overrides
  };
}

describe("startup info", () => {
  it("summarizes deployment settings without exposing the token", () => {
    const info = buildStartupInfo(config({ token: "secret-token-value".repeat(2) }));

    expect(info).toMatchObject({
      app_url_hint: "ws://127.0.0.1:8900/ws",
      workspace_root: "/home/user/workspace",
      allowed_paths: ["/home/user/workspace"],
      token_source: "env",
      token_env: "CCM_TOKEN"
    });
    expect(JSON.stringify(info)).not.toContain("secret-token-value");
  });

  it("uses a placeholder URL when listening on all interfaces", () => {
    const info = buildStartupInfo(config({
      host: "0.0.0.0",
      allowWideBind: true
    }));

    expect(info.app_url_hint).toBe("ws://<server-host>:8900/ws");
  });
});
