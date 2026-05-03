import { describe, expect, it } from "vitest";
import { parseCccRead, parseCccSessionList } from "../src/ccc/ccc-parser.js";

describe("ccc parser", () => {
  it("preserves ccc alive status from ps output", () => {
    const sessions = parseCccSessionList(JSON.stringify([
      {
        name: "dead-demo",
        cwd: "/tmp/demo",
        alive: false
      },
      {
        name: "live-demo",
        cwd: "/tmp/demo",
        alive: true
      }
    ]));

    expect(sessions).toEqual([
      { name: "dead-demo", cwd: "/tmp/demo", state: undefined, alive: false },
      { name: "live-demo", cwd: "/tmp/demo", state: undefined, alive: true }
    ]);
  });

  it("uses lastResponse from ccc read output as assistant output", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: ["screen text"],
      lastResponse: "Hello from Claude\nDone"
    }));

    expect(read).toEqual({
      state: "ready",
      output: "Hello from Claude\nDone",
      pendingApproval: undefined
    });
  });
});
