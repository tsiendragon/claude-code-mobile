import { describe, expect, it } from "vitest";
import { parseCccHistory, parseCccRead, parseCccSessionList } from "../src/ccc/ccc-parser.js";

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
      { name: "dead-demo", cwd: "/tmp/demo", backend: undefined, state: undefined, alive: false },
      { name: "live-demo", cwd: "/tmp/demo", backend: undefined, state: undefined, alive: true }
    ]);
  });

  it("parses ccc backend from ps output", () => {
    const sessions = parseCccSessionList(JSON.stringify([
      {
        name: "codex-demo",
        cwd: "/tmp/demo",
        backend: "codex",
        alive: true
      },
      {
        name: "opencode-demo",
        cwd: "/tmp/demo",
        command: "opencode",
        alive: true
      }
    ]));

    expect(sessions.map((session) => session.backend)).toEqual(["codex", "opencode"]);
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
      items: [{ id: "hist_1", role: "assistant", text: "Hello from Claude\nDone" }],
      pendingApproval: undefined
    });
  });

  it("extracts chat history from ccc read terminal lines", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        "╭─── Claude Code v2.1.126 ─────────────────╮",
        "│           Welcome back Lilong!           │",
        "╰──────────────────────────────────────────╯",
        "",
        "❯ hello",
        "",
        "● ִ Hello! How can I↓help you today?",
        "",
        "✻ Brewed for 1s",
        "",
        "❯ what is the weather",
        "",
        "● ִ I don't have access to real-time weather data or your location. To check the weather, you can:",
        "",
        "  - Search on Google, weather.com, or a similar site",
        "  - Ask a voice assistant (Siri, Google Assistant, etc.)",
        "  - Check a weather app on your phone",
        "",
        "  Is there something else I can help you with?",
        "",
        "✻ Cogitated for 2s",
        "❯  ",
        "  ? for shortcuts"
      ],
      lastResponse: "● ִ I don't have access to real-time weather data or your location.\n✻ Cogitated for 2s"
    }));

    expect(read.items).toEqual([
      { id: "hist_1", role: "user", text: "hello" },
      { id: "hist_2", role: "assistant", text: "Hello! How can I help you today?" },
      { id: "hist_3", role: "user", text: "what is the weather" },
      {
        id: "hist_4",
        role: "assistant",
        text: [
          "I don't have access to real-time weather data or your location. To check the weather, you can:",
          "",
          "- Search on Google, weather.com, or a similar site",
          "- Ask a voice assistant (Siri, Google Assistant, etc.)",
          "- Check a weather app on your phone",
          "",
          "Is there something else I can help you with?"
        ].join("\n")
      }
    ]);
    expect(read.output).toBe("I don't have access to real-time weather data or your location.");
  });

  it("parses ccc history json lines", () => {
    const items = parseCccHistory([
      JSON.stringify({
        ts: 1773153517.928,
        role: "user",
        content: "write report.md",
        event_type: "send"
      }),
      JSON.stringify({
        ts: 1773153530.34,
        role: "assistant",
        content: "● Done\n✻ Brewed for 1s",
        event_type: "response"
      }),
      JSON.stringify({
        ts: 1773153531,
        role: "user",
        content: "ENTER",
        event_type: "send"
      })
    ].join("\n"));

    expect(items).toEqual([
      {
        id: "hist_1",
        role: "user",
        text: "write report.md",
        createdAt: "2026-03-10T14:38:37.928Z",
        snapshot: false
      },
      {
        id: "hist_2",
        role: "assistant",
        text: "Done",
        createdAt: "2026-03-10T14:38:50.340Z",
        snapshot: true
      }
    ]);
  });
});
