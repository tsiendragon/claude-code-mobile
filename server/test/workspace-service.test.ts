import { mkdtemp, mkdir, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { WorkspaceService } from "../src/workspaces/workspace-service.js";

async function tempDir(prefix: string) {
  return mkdtemp(path.join(os.tmpdir(), prefix));
}

describe("WorkspaceService", () => {
  it("creates and lists safe child workspaces under the root", async () => {
    const root = await tempDir("ccm-workspaces-");
    const service = new WorkspaceService({
      workspaceRoot: root,
      allowedPaths: [root],
      allowHiddenCwd: false
    });

    const created = await service.create("demo-app");
    const listed = await service.list();
    const realRoot = await realpath(root);

    expect(created).toMatchObject({
      id: "demo-app",
      name: "demo-app",
      path: path.join(realRoot, "demo-app")
    });
    expect(listed).toEqual([created]);
  });

  it("rejects names that escape or create hidden folders", async () => {
    const root = await tempDir("ccm-workspaces-");
    const service = new WorkspaceService({
      workspaceRoot: root,
      allowedPaths: [root],
      allowHiddenCwd: false
    });

    await expect(service.create("../outside")).rejects.toThrow("WORKSPACE_INVALID");
    await expect(service.create(".secret")).rejects.toThrow("WORKSPACE_INVALID");
  });

  it("requires workspace root to be within allowed paths", async () => {
    const root = await tempDir("ccm-workspaces-");
    const allowed = await tempDir("ccm-allowed-");
    await mkdir(path.join(root, "demo-app"));
    const service = new WorkspaceService({
      workspaceRoot: root,
      allowedPaths: [allowed],
      allowHiddenCwd: false
    });

    await expect(service.list()).rejects.toThrow("PATH_NOT_ALLOWED");
  });
});
