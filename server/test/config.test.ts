import { mkdtemp, writeFile } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { loadConfig } from "../src/config.js";

const envKeys = ["CCM_TEST_TOKEN", "CCM_TOKEN", "CCM_WORKSPACE_ROOT", "CCM_DATA_DIR", "CCM_HOST", "CCM_PORT"];
const originalEnv = new Map(envKeys.map((key) => [key, process.env[key]]));

afterEach(() => {
  for (const key of envKeys) {
    const original = originalEnv.get(key);
    if (original === undefined) {
      delete process.env[key];
    } else {
      process.env[key] = original;
    }
  }
});

describe("loadConfig", () => {
  it("tracks when the token came from the config file", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-config-"));
    const configPath = path.join(dir, "config.json");
    await writeFile(configPath, JSON.stringify({
      token: "c".repeat(32),
      workspace_root: dir,
      allowed_paths: [dir]
    }));

    const config = await loadConfig(configPath);

    expect(config.tokenSource).toBe("config");
    expect(config.token).toBe("c".repeat(32));
  });

  it("tracks when the token came from the configured environment variable", async () => {
    process.env.CCM_TEST_TOKEN = "e".repeat(32);
    delete process.env.CCM_TOKEN;
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-config-"));
    const configPath = path.join(dir, "config.json");
    await writeFile(configPath, JSON.stringify({
      token_env: "CCM_TEST_TOKEN",
      workspace_root: dir,
      allowed_paths: [dir]
    }));

    const config = await loadConfig(configPath);

    expect(config.tokenSource).toBe("env");
    expect(config.tokenEnv).toBe("CCM_TEST_TOKEN");
  });

  it("parses repos, derives ids/names, and expands ~", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-config-"));
    const repoDir = path.join(dir, "my-repo");
    const configPath = path.join(dir, "config.json");
    await writeFile(configPath, JSON.stringify({
      token: "c".repeat(32),
      workspace_root: dir,
      allowed_paths: [dir],
      repos: [
        { name: "My Repo", path: repoDir },
        repoDir
      ]
    }));

    const config = await loadConfig(configPath);

    expect(config.repos).toEqual([
      { id: "my-repo", name: "My Repo", path: repoDir },
      { id: "my-repo-2", name: "my-repo", path: repoDir }
    ]);
  });

  it("rejects repos outside the allowed paths", async () => {
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-config-"));
    const configPath = path.join(dir, "config.json");
    await writeFile(configPath, JSON.stringify({
      token: "c".repeat(32),
      workspace_root: dir,
      allowed_paths: [dir],
      repos: [{ name: "outside", path: "/etc/somewhere" }]
    }));

    await expect(loadConfig(configPath)).rejects.toThrow(/inside an allowed_paths/);
  });

  it("defaults allowed paths to workspace root and home apps", async () => {
    process.env.CCM_TOKEN = "t".repeat(32);
    const dir = await mkdtemp(path.join(os.tmpdir(), "ccm-config-"));
    process.env.CCM_WORKSPACE_ROOT = dir;

    const config = await loadConfig();

    expect(config.allowedPaths).toEqual([
      dir,
      path.join(os.homedir(), "apps")
    ]);
  });
});
