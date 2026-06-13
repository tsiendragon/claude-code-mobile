import http from "node:http";
import { loadConfig } from "./config.js";
import { createLogger } from "./logger.js";
import { CccClient } from "./ccc/ccc-client.js";
import { AuthService } from "./ws/auth.js";
import { WsGateway } from "./ws/gateway.js";
import { InMemoryEventStore } from "./sessions/event-store.js";
import { SessionManager } from "./sessions/session-manager.js";
import { StatePoller } from "./sessions/state-poller.js";
import { TranscriptStore } from "./sessions/transcript-store.js";
import { WorkspaceService } from "./workspaces/workspace-service.js";
import { buildStartupInfo } from "./startup-info.js";
import { createStaticHandler, resolveWebRoot } from "./web/static-server.js";

const configPath = parseConfigPath(process.argv.slice(2));
const config = await loadConfig(configPath);
const logger = createLogger(config.logLevel);

if (config.host === "0.0.0.0") {
  logger.warn("wide_bind_enabled", {
    message: "Bridge Server is listening on all interfaces; use only behind WSS reverse proxy or private network"
  });
}

const webRoot = config.webUiEnabled ? resolveWebRoot(config.webUiDir) : undefined;
const serveWebUi = webRoot ? createStaticHandler(webRoot, logger) : undefined;
if (config.webUiEnabled && !webRoot) {
  logger.warn("web_ui_dir_missing", {
    message: "Web UI enabled but public directory was not found; serving 404 for HTTP requests"
  });
} else if (webRoot) {
  logger.info("web_ui_enabled", { web_root: webRoot });
}

const httpServer = http.createServer((request, response) => {
  logger.info("http_request", {
    method: request.method,
    url: request.url,
    remote_address: request.socket.remoteAddress ?? "unknown"
  });
  if (serveWebUi) {
    serveWebUi(request, response).catch((error) => {
      logger.warn("web_ui_error", { message: error instanceof Error ? error.message : String(error) });
      if (!response.headersSent) response.writeHead(500);
      response.end();
    });
    return;
  }
  response.writeHead(404);
  response.end("Not Found");
});

const events = new InMemoryEventStore(config.eventBufferSize);
const transcripts = new TranscriptStore(config.dataDir);
const ccc = new CccClient(config);
const workspaces = new WorkspaceService(config);
const sessions = new SessionManager(config, ccc, workspaces, events, transcripts);
const poller = new StatePoller(sessions, logger, config.pollIntervalMs);
sessions.setPoller(poller);
const auth = new AuthService(config);
new WsGateway(httpServer, config, logger, auth, sessions, events);

httpServer.listen(config.port, config.host, () => {
  logger.info("bridge_listening", buildStartupInfo(config));
});

function parseConfigPath(args: string[]): string | undefined {
  const index = args.indexOf("--config");
  return index >= 0 ? args[index + 1] : undefined;
}
