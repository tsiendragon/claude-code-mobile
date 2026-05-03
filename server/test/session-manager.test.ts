import { mkdir, mkdtemp, realpath, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import type { BridgeConfig } from "../src/config.js";
import type { CccClient } from "../src/ccc/ccc-client.js";
import { InMemoryEventStore } from "../src/sessions/event-store.js";
import { SessionManager } from "../src/sessions/session-manager.js";
import { WorkspaceService } from "../src/workspaces/workspace-service.js";

function config(root: string): BridgeConfig {
  return {
    host: "127.0.0.1",
    port: 8900,
    tokenEnv: "CCM_TOKEN",
    tokenSource: "env",
    token: "x".repeat(32),
    allowedPaths: [root],
    workspaceRoot: root,
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
    cccTimeoutMs: 15000
  };
}

describe("SessionManager", () => {
  it("skips dead sessions reported by ccc ps", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-sessions-"));
    const cfg = config(root);
    const ccc = {
      listSessions: async () => ({
        ok: true,
        stdout: "",
        stderr: "",
        data: [
          { name: "dead-demo", cwd: root, alive: false },
          { name: "live-demo", cwd: root, alive: true, state: "ready" }
        ]
      })
    } as unknown as CccClient;

    const manager = new SessionManager(
      cfg,
      ccc,
      new WorkspaceService(cfg),
      new InMemoryEventStore(20)
    );

    const sessions = await manager.list();

    expect(sessions.map((session) => session.name)).toEqual(["live-demo"]);
  });

  it("uses a safe internal ccc session name while preserving the display name", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-sessions-"));
    const cfg = config(root);
    const workspaces = new WorkspaceService(cfg);
    await workspaces.create("demo-app");
    const cccCalls: Array<{ name: string; cwd: string }> = [];
    const ccc = {
      runSession: async (name: string, cwd: string, backend: string) => {
        cccCalls.push({ name, cwd });
        expect(backend).toBe("codex");
        return { ok: true, stdout: "", stderr: "", data: { name } } as const;
      }
    } as unknown as CccClient;

    const manager = new SessionManager(cfg, ccc, workspaces, new InMemoryEventStore(20));
    const session = await manager.run({
      name: "Feature branch / prod?",
      backend: "codex",
      workspaceId: "demo-app"
    });
    const realRoot = await realpath(root);

    expect(session.name).toBe("Feature branch / prod?");
    expect(session.backend).toBe("codex");
    expect(session.cccName).toBe(cccCalls[0].name);
    expect(cccCalls[0].name).toMatch(/^feature-branch-prod-[a-f0-9]{8}$/);
    expect(cccCalls[0].cwd).toBe(path.join(realRoot, "demo-app"));
  });

  it("falls back to a generic ccc name when the display name has no ascii slug", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-sessions-"));
    const cfg = config(root);
    const workspaces = new WorkspaceService(cfg);
    await workspaces.create("demo-app");
    let cccName = "";
    const ccc = {
      runSession: async (name: string) => {
        cccName = name;
        return { ok: true, stdout: "", stderr: "", data: { name } } as const;
      }
    } as unknown as CccClient;

    const manager = new SessionManager(cfg, ccc, workspaces, new InMemoryEventStore(20));
    const session = await manager.run({
      name: "测试 会话",
      workspaceId: "demo-app"
    });

    expect(session.name).toBe("测试 会话");
    expect(cccName).toMatch(/^session-[a-f0-9]{8}$/);
  });

  it("submits command replies with Enter while a session is choosing", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-sessions-"));
    const cfg = config(root);
    const workspaces = new WorkspaceService(cfg);
    await workspaces.create("demo-app");
    const calls: string[] = [];
    const ccc = {
      runSession: async (name: string) => {
        return { ok: true, stdout: "", stderr: "", data: { name } } as const;
      },
      input: async (_name: string, command: string) => {
        calls.push(`input:${command}`);
        return { ok: true, stdout: "", stderr: "", data: { name: "demo" } } as const;
      },
      key: async (_name: string, key: string) => {
        calls.push(`key:${key}`);
        return { ok: true, stdout: "", stderr: "", data: { name: "demo", key } } as const;
      }
    } as unknown as CccClient;

    const manager = new SessionManager(cfg, ccc, workspaces, new InMemoryEventStore(20));
    const session = await manager.run({
      name: "Demo",
      workspaceId: "demo-app"
    });
    session.state = "choosing";

    await expect(manager.sendCommand(session.sessionId, "cmsg_abcdef", "1")).resolves.toEqual({ delivered: true });
    expect(calls).toEqual(["input:1", "key:Enter"]);
    expect(session.state).toBe("thinking");
  });

  it("reads files only from the session cwd", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-sessions-"));
    const cfg = config(root);
    const workspaces = new WorkspaceService(cfg);
    await workspaces.create("demo-app");
    const ccc = {
      runSession: async (name: string) => {
        return { ok: true, stdout: "", stderr: "", data: { name } } as const;
      }
    } as unknown as CccClient;

    const manager = new SessionManager(cfg, ccc, workspaces, new InMemoryEventStore(20));
    const session = await manager.run({
      name: "Demo",
      workspaceId: "demo-app"
    });
    await mkdir(session.cwd, { recursive: true });
    await writeFile(path.join(session.cwd, "report.md"), "# Report\n\nHello", "utf8");
    await writeFile(path.join(root, "outside.md"), "# Outside", "utf8");

    await expect(manager.readFile(session.sessionId, "report.md")).resolves.toMatchObject({
      name: "report.md",
      relative_path: "report.md",
      language: "markdown",
      content: "# Report\n\nHello",
      truncated: false
    });
    await expect(manager.resolveFiles(session.sessionId, [
      "report.md",
      "missing.md",
      path.join(root, "outside.md")
    ])).resolves.toMatchObject({
      files: [
        {
          name: "report.md",
          relative_path: "report.md",
          language: "markdown"
        }
      ]
    });
    await expect(manager.readFile(session.sessionId, path.join(root, "outside.md"))).rejects.toThrow("PATH_NOT_ALLOWED");
  });
});
