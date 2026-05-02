import type { BridgeConfig } from "./config.js";

export type StartupInfo = {
  host: string;
  port: number;
  websocket_path: "/ws";
  app_url_hint: string;
  workspace_root: string;
  allowed_paths: string[];
  allow_manual_cwd: boolean;
  allow_hidden_cwd: boolean;
  allow_wide_bind: boolean;
  token_source: BridgeConfig["tokenSource"];
  token_env: string;
  ccc_bin: string;
};

export function buildStartupInfo(config: BridgeConfig): StartupInfo {
  return {
    host: config.host,
    port: config.port,
    websocket_path: "/ws",
    app_url_hint: buildAppUrlHint(config.host, config.port),
    workspace_root: config.workspaceRoot,
    allowed_paths: config.allowedPaths,
    allow_manual_cwd: config.allowManualCwd,
    allow_hidden_cwd: config.allowHiddenCwd,
    allow_wide_bind: config.allowWideBind,
    token_source: config.tokenSource,
    token_env: config.tokenEnv,
    ccc_bin: config.cccBin
  };
}

function buildAppUrlHint(host: string, port: number): string {
  const displayHost = host === "0.0.0.0" ? "<server-host>" : host;
  return `ws://${formatHost(displayHost)}:${port}/ws`;
}

function formatHost(host: string): string {
  if (host === "<server-host>") return host;
  if (host.includes(":") && !host.startsWith("[")) return `[${host}]`;
  return host;
}
