import { describe, expect, it } from "vitest";
import { InMemoryEventStore } from "../src/sessions/event-store.js";

describe("InMemoryEventStore", () => {
  it("keeps a bounded per-session buffer and reports gaps", () => {
    const store = new InMemoryEventStore(2);
    store.append("sess_abcdefgh", { kind: "state_changed", state: "ready" });
    store.append("sess_abcdefgh", { kind: "state_changed", state: "thinking" });
    store.append("sess_abcdefgh", { kind: "state_changed", state: "ready" });

    expect(store.latestSeq("sess_abcdefgh")).toBe(3);
    expect(store.listAfter("sess_abcdefgh", 1)).toHaveLength(2);
    expect(store.listAfter("sess_abcdefgh", 0)).toMatchObject({ type: "EVENT_GAP" });
  });
});
