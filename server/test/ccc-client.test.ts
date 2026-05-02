import { describe, expect, it } from "vitest";
import { CccClient } from "../src/ccc/ccc-client.js";

describe("CccClient", () => {
  it("builds execFile commands without shell strings", () => {
    const client = new CccClient({ cccBin: "ccc", cccTimeoutMs: 1000 });
    expect(client.buildCommand(["send", "session", "hello; rm -rf /", "--no-wait"])).toEqual({
      file: "ccc",
      args: ["send", "session", "hello; rm -rf /", "--no-wait"]
    });
  });
});
