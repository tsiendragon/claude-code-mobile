import { readFile } from "node:fs/promises";
import { randomBytes } from "node:crypto";
import path from "node:path";
import type { LogLevel } from "./logger.js";
import { expandHome } from "./security/paths.js";

export type RepoConfig = {
  id: string;
  name: string;
  path: string;
};

export type BridgeConfig = {
  host: string;
  port: number;
  tokenEnv: string;
  tokenSource: "config" | "env" | "generated";
  token: string;
  allowedPaths: string[];
  repos: RepoConfig[];
  workspaceRoot: string;
  dataDir: string;
  allowManualCwd: boolean;
  cccBin: string;
  pollIntervalMs: number;
  eventBufferSize: number;
  maxPromptBytes: number;
  maxWsMessageBytes: number;
  maxEventBytes: number;
  allowWideBind: boolean;
  allowHiddenCwd: boolean;
  logLevel: LogLevel;
  cccTimeoutMs: number;
  webUiEnabled: boolean;
  webUiDir?: string;
};

type RawConfig = {
  host?: string;
  port?: number;
  token?: string;
  token_env?: string;
  allowed_paths?: string[];
  repos?: Array<{ name?: string; path: string } | string>;
  workspace_root?: string;
  data_dir?: string;
  allow_manual_cwd?: boolean;
  ccc_bin?: string;
  poll_interval_ms?: number;
  event_buffer_size?: number;
  max_prompt_bytes?: number;
  max_ws_message_bytes?: number;
  max_event_bytes?: number;
  allow_wide_bind?: boolean;
  allow_hidden_cwd?: boolean;
  log_level?: LogLevel;
  ccc_timeout_ms?: number;
  web_ui_enabled?: boolean;
  web_ui_dir?: string;
};

export async function loadConfig(configPath?: string): Promise<BridgeConfig> {
  const raw = configPath ? await readJsonConfig(configPath) : {};
  const tokenEnv = raw.token_env ?? "CCM_TOKEN";
  const configuredToken = raw.token;
  const envToken = process.env[tokenEnv];
  const token = configuredToken ?? envToken ?? generateDevToken();
  const tokenSource = configuredToken ? "config" : envToken ? "env" : "generated";
  const workspaceRoot = expandHome(raw.workspace_root ?? process.env.CCM_WORKSPACE_ROOT ?? "~/workspace");
  const allowedPaths = raw.allowed_paths
    ? raw.allowed_paths.map(expandHome)
    : uniquePaths([workspaceRoot, "~/apps"]);
  const dataDir = expandHome(raw.data_dir ?? process.env.CCM_DATA_DIR ?? "~/.ccm-bridge");
  const repos = parseRepos(raw.repos);

  const config: BridgeConfig = {
    host: raw.host ?? process.env.CCM_HOST ?? "127.0.0.1",
    port: raw.port ?? numberFromEnv("CCM_PORT", 8900),
    tokenEnv,
    tokenSource,
    token,
    allowedPaths,
    repos,
    workspaceRoot,
    dataDir,
    allowManualCwd: raw.allow_manual_cwd ?? true,
    cccBin: raw.ccc_bin ?? process.env.CCM_CCC_BIN ?? "ccc",
    pollIntervalMs: raw.poll_interval_ms ?? 1000,
    eventBufferSize: raw.event_buffer_size ?? 200,
    maxPromptBytes: raw.max_prompt_bytes ?? 102400,
    maxWsMessageBytes: raw.max_ws_message_bytes ?? 262144,
    maxEventBytes: raw.max_event_bytes ?? 524288,
    allowWideBind: raw.allow_wide_bind ?? false,
    allowHiddenCwd: raw.allow_hidden_cwd ?? false,
    logLevel: raw.log_level ?? "info",
    cccTimeoutMs: raw.ccc_timeout_ms ?? 15000,
    webUiEnabled: raw.web_ui_enabled ?? envFlag("CCM_WEB_UI", true),
    webUiDir: raw.web_ui_dir ? expandHome(raw.web_ui_dir) : process.env.CCM_WEB_UI_DIR ? expandHome(process.env.CCM_WEB_UI_DIR) : undefined
  };

  validateConfig(config);
  return config;
}

function validateConfig(config: BridgeConfig) {
  if (typeof process.getuid === "function" && process.getuid() === 0) {
    throw new Error("Bridge Server refuses to run as root");
  }
  if (config.host === "0.0.0.0" && !config.allowWideBind) {
    throw new Error("Binding 0.0.0.0 requires allow_wide_bind: true");
  }
  if (config.allowedPaths.length === 0) {
    throw new Error("allowed_paths is required");
  }
  if (!path.isAbsolute(config.workspaceRoot)) {
    throw new Error("workspace_root must be absolute or start with ~");
  }
  if (config.workspaceRoot === "/") {
    throw new Error("workspace_root must not be /");
  }
  if (!path.isAbsolute(config.dataDir)) {
    throw new Error("data_dir must be absolute or start with ~");
  }
  if (config.dataDir === "/") {
    throw new Error("data_dir must not be /");
  }
  for (const allowedPath of config.allowedPaths) {
    if (!path.isAbsolute(allowedPath)) {
      throw new Error("allowed_paths must be absolute or start with ~");
    }
  }
  if (config.allowedPaths.includes("/")) {
    throw new Error("allowed_paths must not include /");
  }
  for (const repo of config.repos) {
    if (!path.isAbsolute(repo.path)) {
      throw new Error(`repo "${repo.name}" path must be absolute or start with ~`);
    }
    const inAllowed = config.allowedPaths.some(
      (allowed) => repo.path === allowed || repo.path.startsWith(`${allowed}${path.sep}`)
    );
    if (!inAllowed) {
      throw new Error(`repo "${repo.name}" path must be inside an allowed_paths entry`);
    }
  }
  if (Buffer.byteLength(config.token) < 32) {
    throw new Error("token must be at least 32 bytes");
  }
}

async function readJsonConfig(configPath: string): Promise<RawConfig> {
  const body = await readFile(configPath, "utf8");
  return JSON.parse(body) as RawConfig;
}

function envFlag(name: string, fallback: boolean): boolean {
  const value = process.env[name];
  if (value === undefined) return fallback;
  return value !== "0" && value.toLowerCase() !== "false";
}

function numberFromEnv(name: string, fallback: number): number {
  const value = process.env[name];
  if (!value) return fallback;
  const parsed = Number(value);
  return Number.isInteger(parsed) ? parsed : fallback;
}

function uniquePaths(paths: string[]): string[] {
  return [...new Set(paths.map(expandHome))];
}

function parseRepos(raw: RawConfig["repos"]): RepoConfig[] {
  if (!raw) return [];
  const repos: RepoConfig[] = [];
  const seenIds = new Set<string>();
  for (const entry of raw) {
    const rawPath = typeof entry === "string" ? entry : entry?.path;
    if (typeof rawPath !== "string" || rawPath.trim().length === 0) {
      throw new Error("repos entries must have a non-empty path");
    }
    const expandedPath = expandHome(rawPath.trim());
    const rawName = typeof entry === "string" ? undefined : entry.name?.trim();
    const name = rawName && rawName.length > 0 ? rawName : path.basename(expandedPath);
    const id = makeRepoId(name, seenIds);
    seenIds.add(id);
    repos.push({ id, name, path: expandedPath });
  }
  return repos;
}

function makeRepoId(name: string, taken: Set<string>): string {
  const base = name.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "") || "repo";
  let id = base;
  let suffix = 2;
  while (taken.has(id)) {
    id = `${base}-${suffix}`;
    suffix += 1;
  }
  return id;
}

function generateDevToken(): string {
  const token = randomBytes(32).toString("base64url");
  console.warn(JSON.stringify({
    ts: new Date().toISOString(),
    level: "warn",
    event: "dev_token_generated",
    message: "No token configured; generated a one-time development token",
    token
  }));
  return token;
}
