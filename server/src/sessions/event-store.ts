import type { DomainEvent, EventGap, StoredEvent } from "../types/domain.js";

type BufferState = {
  latestSeq: number;
  events: StoredEvent[];
};

export type EventListener = (event: StoredEvent) => void;

export class InMemoryEventStore {
  private readonly sessions = new Map<string, BufferState>();
  private readonly listeners = new Set<EventListener>();

  constructor(private readonly bufferSize: number) {}

  append(sessionId: string, event: DomainEvent): StoredEvent {
    const state = this.sessions.get(sessionId) ?? { latestSeq: 0, events: [] };
    const stored: StoredEvent = {
      type: "event",
      session_id: sessionId,
      seq: state.latestSeq + 1,
      event,
      created_at: new Date().toISOString()
    };
    state.latestSeq = stored.seq;
    state.events.push(stored);
    if (state.events.length > this.bufferSize) {
      state.events.splice(0, state.events.length - this.bufferSize);
    }
    this.sessions.set(sessionId, state);
    for (const listener of this.listeners) listener(stored);
    return stored;
  }

  latestSeq(sessionId: string): number {
    return this.sessions.get(sessionId)?.latestSeq ?? 0;
  }

  listAfter(sessionId: string, seq: number): StoredEvent[] | EventGap {
    const state = this.sessions.get(sessionId);
    if (!state) return { type: "EVENT_GAP", latestSeq: 0 };
    const oldestSeq = state.events[0]?.seq;
    if (oldestSeq !== undefined && seq < oldestSeq - 1) {
      return { type: "EVENT_GAP", latestSeq: state.latestSeq, oldestSeq };
    }
    return state.events.filter((event) => event.seq > seq);
  }

  clear(sessionId: string): void {
    this.sessions.delete(sessionId);
  }

  subscribe(listener: EventListener): () => void {
    this.listeners.add(listener);
    return () => this.listeners.delete(listener);
  }
}
