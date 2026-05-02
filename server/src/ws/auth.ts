import { randomUUID } from "node:crypto";
import type { BridgeConfig } from "../config.js";
import { constantTimeTokenEqual, parseBearer } from "../security/token.js";
import { AuthFailureTracker } from "../security/rate-limit.js";
import type { AuthRequest, RequestEnvelope } from "../types/protocol.js";

export type AuthResult =
  | { ok: true; principalId: string }
  | { ok: false; code: "AUTH_FAILED" | "RATE_LIMITED"; message: string };

export class AuthService {
  private token: string;
  private tokenVersion = randomUUID();

  constructor(
    config: BridgeConfig,
    private readonly failures = new AuthFailureTracker()
  ) {
    this.token = config.token;
  }

  authenticate(request: RequestEnvelope | AuthRequest, remoteAddress: string): AuthResult {
    if (this.failures.isBlocked(remoteAddress)) {
      return { ok: false, code: "RATE_LIMITED", message: "too many authentication failures" };
    }

    const token = typeof request.token === "string" ? request.token : parseBearer(request.authorization);
    if (!token || !constantTimeTokenEqual(token, this.token)) {
      this.failures.recordFailure(remoteAddress);
      return { ok: false, code: "AUTH_FAILED", message: "token invalid" };
    }

    this.failures.clear(remoteAddress);
    return { ok: true, principalId: "local-user" };
  }

  rotateToken(nextToken: string): string {
    this.token = nextToken;
    this.tokenVersion = randomUUID();
    return this.tokenVersion;
  }

  currentTokenVersion(): string {
    return this.tokenVersion;
  }
}
