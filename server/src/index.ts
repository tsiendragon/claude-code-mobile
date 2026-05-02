import http from "node:http";
import { loadConfig } from "./config.js";
import { createLogger } from "./logger.js";
import { CccClient } from "./ccc/ccc-client.js";
import { AuthService } from "./ws/auth.js";
import { WsGateway } from "./ws/gateway.js";
import { InMemoryEventStore } from "./sessions/event-store.js";
import { SessionManager } from "./sessions/session-manager.js";
import { StatePoller } from "./sessions/state-poller.js";
import { WorkspaceService } from "./workspaces/workspace-service.js";
import { buildStartupInfo } from "./startup-info.js";

const configPath = parseConfigPath(process.argv.slice(2));
const config = await loadConfig(configPath);
const logger = createLogger(config.logLevel);

if (config.host === "0.0.0.0") {
  logger.warn("wide_bind_enabled", {
    message: "Bridge Server is listening on all interfaces; use only behind WSS reverse proxy or private network"
  });
}

const httpServer = http.createServer((_request, response) => {
  response.writeHead(404);
  response.end("Not Found");
});

const events = new InMemoryEventStore(config.eventBufferSize);
const ccc = new CccClient(config);
const workspaces = new WorkspaceService(config);
const sessions = new SessionManager(config, ccc, workspaces, events);
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
