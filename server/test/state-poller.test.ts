import { afterEach, describe, expect, it, vi } from "vitest";
import type { Logger } from "../src/logger.js";
import type { SessionManager } from "../src/sessions/session-manager.js";
import { StatePoller } from "../src/sessions/state-poller.js";

function logger(): Logger {
  return {
    debug: vi.fn(),
    info: vi.fn(),
    warn: vi.fn(),
    error: vi.fn()
  };
}

afterEach(() => {
  vi.useRealTimers();
});

describe("StatePoller", () => {
  it("does not reschedule an in-flight poll after stop", async () => {
    vi.useFakeTimers();
    let rejectSnapshot!: (error: Error) => void;
    const snapshot = new Promise<never>((_resolve, reject) => {
      rejectSnapshot = reject;
    });
    const manager = {
      applySnapshot: vi.fn(() => snapshot)
    } as unknown as SessionManager;
    const testLogger = logger();
    const poller = new StatePoller(manager, testLogger, 1000);

    poller.start("sess_abcdefgh");
    await vi.advanceTimersByTimeAsync(1000);
    expect(manager.applySnapshot).toHaveBeenCalledTimes(1);

    poller.stop("sess_abcdefgh");
    rejectSnapshot(new Error("SESSION_NOT_FOUND"));
    await vi.runOnlyPendingTimersAsync();
    await vi.advanceTimersByTimeAsync(30000);

    expect(testLogger.warn).not.toHaveBeenCalled();
    expect(manager.applySnapshot).toHaveBeenCalledTimes(1);
  });
});
