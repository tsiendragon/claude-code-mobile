import type { Logger } from "../logger.js";
import type { SessionManager } from "./session-manager.js";

export class StatePoller {
  private readonly timers = new Map<string, NodeJS.Timeout>();
  private readonly failures = new Map<string, number>();

  constructor(
    private readonly manager: SessionManager,
    private readonly logger: Logger,
    private readonly baseIntervalMs: number
  ) {}

  start(sessionId: string) {
    if (this.timers.has(sessionId)) return;
    this.schedule(sessionId, this.baseIntervalMs);
  }

  stop(sessionId: string) {
    const timer = this.timers.get(sessionId);
    if (timer) clearTimeout(timer);
    this.timers.delete(sessionId);
    this.failures.delete(sessionId);
  }

  private schedule(sessionId: string, delayMs: number) {
    const timer = setTimeout(() => void this.tick(sessionId), delayMs);
    this.timers.set(sessionId, timer);
  }

  private async tick(sessionId: string) {
    if (!this.timers.has(sessionId)) return;
    try {
      const session = await this.manager.applySnapshot(sessionId);
      if (!this.timers.has(sessionId)) return;
      this.failures.delete(sessionId);
      if (session.state === "ended") {
        this.stop(sessionId);
        return;
      }
      this.schedule(sessionId, session.state === "ready" ? this.baseIntervalMs * 3 : this.baseIntervalMs);
    } catch (error) {
      if (!this.timers.has(sessionId)) return;
      const msg = error instanceof Error ? error.message : String(error);
      // Permanent failures (session/server gone) — stop polling immediately
      if (
        msg.includes("no server running") ||
        msg.includes("session not found") ||
        msg.includes("SESSION_NOT_FOUND") ||
        msg.includes("can't find session") ||
        /No session ['"]/.test(msg)
      ) {
        this.stop(sessionId);
        this.logger.warn("state_poll_stopped", { session_id: sessionId, reason: "permanent_failure", message: msg });
        return;
      }
      const count = (this.failures.get(sessionId) ?? 0) + 1;
      this.failures.set(sessionId, count);
      this.logger.warn("state_poll_failed", {
        session_id: sessionId,
        failures: count,
        message: msg
      });
      // After 5 consecutive failures, stop polling (session is likely dead)
      if (count >= 5) {
        this.stop(sessionId);
        this.logger.warn("state_poll_stopped", { session_id: sessionId, reason: "too_many_failures", failures: count });
        return;
      }
      this.schedule(sessionId, this.baseIntervalMs * (count >= 3 ? 10 : 2));
    }
  }
}
