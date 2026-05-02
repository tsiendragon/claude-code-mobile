import path from "node:path";
import { mkdir, readdir, realpath } from "node:fs/promises";
import type { BridgeConfig } from "../config.js";
import { assertAllowedCwd, expandHome, isPathInside } from "../security/paths.js";

export type WorkspaceSummary = {
  id: string;
  name: string;
  path: string;
};

type WorkspaceConfig = Pick<BridgeConfig, "workspaceRoot" | "allowedPaths" | "allowHiddenCwd">;

export class WorkspaceService {
  constructor(private readonly config: WorkspaceConfig) {}

  async list(): Promise<WorkspaceSummary[]> {
    const root = await this.ensureRoot();
    const entries = await readdir(root, { withFileTypes: true });
    const workspaces: WorkspaceSummary[] = [];

    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (!this.config.allowHiddenCwd && entry.name.startsWith(".")) continue;
      if (!isWorkspaceSegment(entry.name, this.config.allowHiddenCwd)) continue;

      const workspacePath = await this.resolveWorkspacePath(entry.name);
      workspaces.push({ id: entry.name, name: entry.name, path: workspacePath });
    }

    workspaces.sort((a, b) => a.name.localeCompare(b.name));
    return workspaces;
  }

  async create(name: string): Promise<WorkspaceSummary> {
    const id = normalizeWorkspaceName(name, this.config.allowHiddenCwd);
    const root = await this.ensureRoot();
    const target = path.join(root, id);

    if (!isPathInside(path.resolve(target), root)) {
      throw new Error("WORKSPACE_INVALID: workspace escapes workspace_root");
    }

    await mkdir(target, { recursive: false }).catch(async (error: NodeJS.ErrnoException) => {
      if (error.code !== "EEXIST") throw error;
      const resolved = await realpath(target);
      if (!isPathInside(resolved, root)) {
        throw new Error("PATH_NOT_ALLOWED: workspace resolves outside workspace_root");
      }
    });

    const workspacePath = await this.resolveWorkspacePath(id);
    return { id, name: id, path: workspacePath };
  }

  async resolveWorkspaceCwd(workspaceId: string): Promise<string> {
    const id = normalizeWorkspaceName(workspaceId, this.config.allowHiddenCwd);
    return this.resolveWorkspacePath(id);
  }

  private async ensureRoot(): Promise<string> {
    const rootCandidate = expandHome(this.config.workspaceRoot);
    await mkdir(rootCandidate, { recursive: true });
    return assertAllowedCwd(rootCandidate, this.config.allowedPaths, {
      allowHiddenCwd: this.config.allowHiddenCwd
    });
  }

  private async resolveWorkspacePath(workspaceId: string): Promise<string> {
    const root = await this.ensureRoot();
    const target = path.join(root, workspaceId);
    const resolved = await assertAllowedCwd(target, this.config.allowedPaths, {
      allowHiddenCwd: this.config.allowHiddenCwd
    });
    if (!isPathInside(resolved, root)) {
      throw new Error("PATH_NOT_ALLOWED: workspace resolves outside workspace_root");
    }
    return resolved;
  }
}

function normalizeWorkspaceName(input: string, allowHidden: boolean): string {
  const name = input.trim();
  if (!isWorkspaceSegment(name, allowHidden)) {
    throw new Error("WORKSPACE_INVALID: workspace name must be a safe folder name");
  }
  return name;
}

function isWorkspaceSegment(name: string, allowHidden: boolean): boolean {
  if (name.length === 0 || name.length > 80) return false;
  if (name === "." || name === "..") return false;
  if (!allowHidden && name.startsWith(".")) return false;
  return /^[a-zA-Z0-9][a-zA-Z0-9._-]*$/.test(name);
}
