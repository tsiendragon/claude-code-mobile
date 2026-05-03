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
});
