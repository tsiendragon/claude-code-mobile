import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { describe, expect, it } from "vitest";
import { parseCccHistory, parseCccRead, parseCccSessionList } from "../src/ccc/ccc-parser.js";

function loadFixture(name: string): string {
  return readFileSync(fileURLToPath(new URL(`./fixtures/ccc-parse/${name}`, import.meta.url)), "utf8");
}

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

  it("strips the Claude Code v2 banner when ccc read output is a full screen dump", () => {
    // Regression: captured as a real badcase. ccc v0.3.0 + Claude Code v2.1.177
    // returned the entire screen (banner, setup warning, prompt, separators,
    // status bar) in lastResponse, which leaked into the assistant bubble.
    const sep = "─".repeat(80);
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        " ▐▛███▜▌   Claude Code v2.1.177",
        "▝▜█████▛▘  Opus 4.8 (1M context) · Claude Enterprise",
        "  ▘▘ ▝▝    ~/workspace/demo",
        "",
        " ⚠ 3 setup issues: MCP · /doctor",
        "",
        "❯ Do not edit files. Reply with exactly: OK",
        "",
        "● OK",
        "",
        "✻ Baked for 1s",
        "",
        sep,
        "❯ ",
        sep,
        "    [Opus 4.8] ▎░░░░░░░░░ 3% (1M) │ 5h:10% (4.4h)            ● high · /effort",
        "  ← for agents"
      ],
      lastResponse: [
        "▐▛███▜▌   Claude Code v2.1.177",
        "▝▜█████▛▘  Opus 4.8 (1M context) · Claude Enterprise",
        "  ▘▘ ▝▝    ~/workspace/demo",
        " ⚠ 3 setup issues: MCP · /doctor",
        "❯ Do not edit files. Reply with exactly: OK",
        "● OK",
        "✻ Baked for 1s",
        sep,
        "❯ ",
        sep,
        "    [Opus 4.8] ▎░░░░░░░░░ 3% (1M) │ 5h:10% (4.4h)            ● high · /effort",
        "  ← for agents"
      ].join("\n")
    }));

    expect(read.output).toBe("OK");
    expect(read.items).toEqual([
      { id: "hist_1", role: "user", text: "Do not edit files. Reply with exactly: OK" },
      { id: "hist_2", role: "assistant", text: "OK" }
    ]);
  });

  it("drops a banner-only welcome screen instead of rendering it as a response", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        " ▐▛███▜▌   Claude Code v2.1.177",
        "▝▜█████▛▘  Opus 4.8 (1M context) · Claude Enterprise",
        "  ▘▘ ▝▝    ~/workspace/demo"
      ],
      lastResponse: [
        "▐▛███▜▌   Claude Code v2.1.177",
        "▝▜█████▛▘  Opus 4.8 (1M context) · Claude Enterprise",
        "  ▘▘ ▝▝    ~/workspace/demo"
      ].join("\n")
    }));

    expect(read.output).toBeUndefined();
    expect(read.items).toBeUndefined();
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

  it("removes Claude Code welcome chrome from ccc history responses", () => {
    const items = parseCccHistory([
      JSON.stringify({
        ts: 1773153517.928,
        role: "user",
        content: "hello",
        event_type: "send"
      }),
      JSON.stringify({
        ts: 1773153530.34,
        role: "assistant",
        content: [
          "╭─── Claude Code v2.1.126 ─────────────────╮",
          "│           Welcome back Lilong!           │",
          "╰──────────────────────────────────────────╯",
          "❯ hello",
          "",
          "⏺ Hello! How can I help?",
          "",
          "✻ Brewed for 1s"
        ].join("\n"),
        event_type: "response"
      }),
      JSON.stringify({
        ts: 1773153531,
        role: "assistant",
        content: [
          "╭─── Claude Code v2.1.126 ─────────────────╮",
          "│           Welcome back Lilong!           │",
          "╰──────────────────────────────────────────╯",
          "❯ "
        ].join("\n"),
        event_type: "response"
      })
    ].join("\n"));

    expect(items.map((item) => item.text)).toEqual([
      "hello",
      "Hello! How can I help?"
    ]);
  });

  it("detects numbered choice prompts from ccc read output", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        "✨ Update available! 0.128.0 -> 0.130.0",
        "",
        "Release notes: https://github.com/openai/codex/releases/latest",
        "",
        "› 1. Update now (runs `npm install -g @openai/codex`)",
        "  2. Skip",
        "  3. Skip until next version",
        "",
        "Press enter to continue"
      ]
    }));

    expect(read.state).toBe("choosing");
    expect(read.pendingApproval).toMatchObject({
      operationKind: "choice",
      actions: ["choice"],
      choices: [
        { value: "1", label: "Update now (runs `npm install -g @openai/codex`)" },
        { value: "2", label: "Skip" },
        { value: "3", label: "Skip until next version" }
      ]
    });
  });

  // Regression: Claude Code highlights the selected option with ❯ (U+276F), not the
  // codex › (U+203A). The parser used to ignore ❯, so the first/primary "Yes" option
  // was dropped from the approval card entirely (only "allow all edits" and "No" showed).
  it("captures the ❯-highlighted first option in Claude Code approval prompts", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        " Do you want to create approval_probe.txt?",
        " ❯ 1. Yes",
        "   2. Yes, allow all edits during this session (shift+tab)",
        "   3. No",
        "",
        " Esc to cancel · Tab to amend"
      ]
    }));

    expect(read.state).toBe("choosing");
    expect(read.pendingApproval).toMatchObject({
      operationKind: "choice",
      actions: ["choice"],
      choices: [
        { value: "1", label: "Yes" },
        { value: "2", label: "Yes, allow all edits during this session (shift+tab)" },
        { value: "3", label: "No" }
      ]
    });
    expect(read.pendingApproval?.description.split("\n")[0]).toBe(
      "Do you want to create approval_probe.txt?"
    );
  });

  // Regression: a single Claude turn renders as multiple ● bullets (intro text,
  // a Bash tool block, closing text). The extractor used to keep only the last
  // bullet, so the phone showed a truncated reply (missing intro + command block)
  // that didn't match the real session.
  it("keeps every bullet of a multi-part assistant turn (text + command block)", () => {
    const output = [
      "❯ 后端更新了",
      "● 好,后端更新了,先验证一下重复渲染还在不在。",
      "  这条回复有一定长度,可以当测试样本。",
      "● Bash(echo \"render check\"; df -h | head -2)",
      "  ⎿  render check",
      "     Filesystem  Size  Used Avail Use%",
      "● 上面这条带正文 + 命令块的消息也截一下,两张图对比。",
      "✻ Cogitated for 17s"
    ].join("\n");
    const read = parseCccRead(JSON.stringify({ state: "ready", output }));

    expect(read.output).toContain("好,后端更新了");
    expect(read.output).toContain("Bash(echo");
    expect(read.output).toContain("render check");
    expect(read.output).toContain("上面这条带正文");
    expect(read.state).toBe("ready");
  });

  // Regression: a snapshot frame often captures the live prompt + animated status
  // bar/spinner below the reply. Leaving that chrome in the extracted text made
  // each poll differ, so the same answer was stored (and rendered) 2-3 times.
  it("strips trailing prompt/status-bar/spinner chrome from the assistant reply", () => {
    const output = [
      "● 第 11 条单独重发完成。需要别的序号继续报数字就行。",
      "",
      "❯",
      "[Opus 4.8] ▍░░░░░░░░░ 4% (1M) │ 5h:2% (4.3h) │ 7d:19% (9.5h)",
      "  ← for agents",
      "✻ Cooked for 8s"
    ].join("\n");
    const read = parseCccRead(JSON.stringify({ state: "ready", output }));

    expect(read.output).toBe("第 11 条单独重发完成。需要别的序号继续报数字就行。");
    expect(read.state).toBe("ready");
  });

  // Regression: a plain numbered list in an assistant reply (no ❯/› cursor) must
  // NOT be mistaken for a live selection menu. This produced an endless re-prompt
  // loop — the user picked an option, the assistant answered with more numbered
  // text, and the bridge re-opened the "choice" every poll.
  it("does not treat a cursor-less numbered list as a choice prompt", () => {
    const read = parseCccRead(JSON.stringify({
      state: "ready",
      lines: [
        "● Here are a few options to consider:",
        "  1. Run the migration now",
        "  2. Schedule it for tonight",
        "  3. Skip it",
        "",
        "❯ "
      ]
    }));

    expect(read.state).toBe("ready");
    expect(read.pendingApproval).toBeUndefined();
  });

  // Regression captured live via the web console + Playwright: `ccc read --json` returns
  // a full-screen pane dump where stale output (a prior "count to 200" reply) sits above
  // the live approval prompt. The title scan used to grab the first non-numbered line in
  // the whole dump ("190") instead of the actual question, and the ❯ option was lost.
  // Fixtures: approval_raw.txt (raw tmux pane) + approval_ccc_read.json (ccc read --json).
  it("parses the real captured file-write approval without leaking stale pane output", () => {
    const read = parseCccRead(loadFixture("approval_ccc_read.json"));

    expect(read.state).toBe("choosing");
    expect(read.pendingApproval?.operationKind).toBe("choice");
    expect(read.pendingApproval?.choices).toEqual([
      { value: "1", label: "Yes" },
      { value: "2", label: "Yes, allow all edits during this session (shift+tab)" },
      { value: "3", label: "No" }
    ]);

    const title = read.pendingApproval?.description.split("\n")[0];
    expect(title).toBe("Do you want to create approval_probe.txt?");
    expect(title).not.toBe("190");
  });

  // Baseline captured live (Codex backend, codex-cli 0.139.0): a clean reply with no
  // pending approval. Codex marks turns with • / › rather than ● / ❯, so the assistant
  // text is recovered from the lastResponse field rather than the pane line scan.
  // Fixture: codex_ready.json (ccc read --json).
  it("parses a clean Codex reply with no pending approval", () => {
    const read = parseCccRead(loadFixture("codex_ready.json"));

    expect(read.state).toBe("ready");
    expect(read.output).toBe("KIWI");
    expect(read.pendingApproval).toBeUndefined();
    expect(read.items?.some((item) => item.role === "assistant" && item.text === "KIWI")).toBe(true);
  });
});
