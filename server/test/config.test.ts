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
});
