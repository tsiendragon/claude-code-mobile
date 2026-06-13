import { createReadStream, statSync } from "node:fs";
import { stat } from "node:fs/promises";
import http from "node:http";
import path from "node:path";
import { fileURLToPath } from "node:url";
import type { Logger } from "../logger.js";

const MIME_TYPES: Record<string, string> = {
  ".html": "text/html; charset=utf-8",
  ".js": "text/javascript; charset=utf-8",
  ".mjs": "text/javascript; charset=utf-8",
  ".css": "text/css; charset=utf-8",
  ".json": "application/json; charset=utf-8",
  ".svg": "image/svg+xml",
  ".png": "image/png",
  ".jpg": "image/jpeg",
  ".jpeg": "image/jpeg",
  ".gif": "image/gif",
  ".webp": "image/webp",
  ".ico": "image/x-icon",
  ".woff": "font/woff",
  ".woff2": "font/woff2",
  ".map": "application/json; charset=utf-8",
  ".txt": "text/plain; charset=utf-8"
};

/**
 * Resolves the WebUI public directory. Works for both `npm run dev` (tsx, sources
 * under src/) and the compiled build (dist/src/). An explicit override always wins.
 */
export function resolveWebRoot(override?: string): string | undefined {
  if (override) {
    return path.resolve(override);
  }
  const here = path.dirname(fileURLToPath(import.meta.url));
  const candidates = [
    path.resolve(here, "../../../public"), // dist/src/web -> server/public
    path.resolve(here, "../../public") // src/web -> server/public
  ];
  return candidates.find((candidate) => existsSyncSafe(candidate));
}

function existsSyncSafe(target: string): boolean {
  try {
    return statSync(target).isDirectory();
  } catch {
    return false;
  }
}

/**
 * Builds an HTTP request handler that serves static files from `webRoot`.
 * `/` and unknown non-file paths fall back to index.html so the SPA can route.
 * WebSocket upgrade requests are handled separately by the ws server.
 */
export function createStaticHandler(webRoot: string, logger: Logger) {
  return async function handle(
    request: http.IncomingMessage,
    response: http.ServerResponse
  ): Promise<void> {
    if (request.method !== "GET" && request.method !== "HEAD") {
      response.writeHead(405, { Allow: "GET, HEAD" });
      response.end("Method Not Allowed");
      return;
    }

    const requestUrl = request.url ?? "/";
    // The WS endpoints are not served as files.
    if (requestUrl === "/ws") {
      response.writeHead(426);
      response.end("Upgrade Required");
      return;
    }

    const decodedPath = safeDecode(requestUrl.split("?")[0] ?? "/");
    if (decodedPath === undefined) {
      response.writeHead(400);
      response.end("Bad Request");
      return;
    }

    const relative = decodedPath === "/" ? "index.html" : decodedPath.replace(/^\/+/, "");
    const resolved = path.resolve(webRoot, relative);

    // Containment check: never serve anything outside the web root.
    if (resolved !== webRoot && !resolved.startsWith(webRoot + path.sep)) {
      logger.warn("web_path_rejected", { path: requestUrl });
      response.writeHead(403);
      response.end("Forbidden");
      return;
    }

    const filePath = await resolveExistingFile(resolved, webRoot);
    if (!filePath) {
      response.writeHead(404);
      response.end("Not Found");
      return;
    }

    const ext = path.extname(filePath).toLowerCase();
    const contentType = MIME_TYPES[ext] ?? "application/octet-stream";
    const info = await stat(filePath);
    response.writeHead(200, {
      "Content-Type": contentType,
      "Content-Length": info.size,
      "Cache-Control": "no-cache",
      "X-Content-Type-Options": "nosniff"
    });
    if (request.method === "HEAD") {
      response.end();
      return;
    }
    createReadStream(filePath)
      .on("error", () => {
        if (!response.headersSent) response.writeHead(500);
        response.end();
      })
      .pipe(response);
  };
}

async function resolveExistingFile(resolved: string, webRoot: string): Promise<string | undefined> {
  const info = await stat(resolved).catch(() => undefined);
  if (info?.isFile()) return resolved;
  if (info?.isDirectory()) {
    const indexFile = path.join(resolved, "index.html");
    const indexInfo = await stat(indexFile).catch(() => undefined);
    if (indexInfo?.isFile()) return indexFile;
  }
  // SPA fallback: unknown route with no extension -> index.html
  if (!path.extname(resolved)) {
    const fallback = path.join(webRoot, "index.html");
    const fallbackInfo = await stat(fallback).catch(() => undefined);
    if (fallbackInfo?.isFile()) return fallback;
  }
  return undefined;
}

function safeDecode(value: string): string | undefined {
  try {
    const decoded = decodeURIComponent(value);
    if (decoded.includes("\0")) return undefined;
    return decoded;
  } catch {
    return undefined;
  }
}
