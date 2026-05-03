import { describe, expect, it } from "vitest";
import { CccClient } from "../src/ccc/ccc-client.js";

describe("CccClient", () => {
  it("builds run commands for the current ccc CLI", () => {
    const client = new CccClient({ cccBin: "ccc", cccTimeoutMs: 1000 });
    expect(client.buildRunSessionArgs("demo", "/tmp/demo")).toEqual(["run", "demo", "--cwd", "/tmp/demo"]);
  });

  it("builds execFile commands without shell strings", () => {
    const client = new CccClient({ cccBin: "ccc", cccTimeoutMs: 1000 });
    expect(client.buildCommand(["send", "session", "hello; rm -rf /", "--no-wait"])).toEqual({
      file: "ccc",
      args: ["send", "session", "hello; rm -rf /", "--no-wait"]
    });
    expect(client.buildCommand(["key", "session", "Enter"])).toEqual({
      file: "ccc",
      args: ["key", "session", "Enter"]
    });
  });
});
