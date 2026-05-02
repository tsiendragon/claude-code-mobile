import { describe, expect, it } from "vitest";
import { constantTimeTokenEqual, parseBearer } from "../src/security/token.js";

describe("token helpers", () => {
  it("parses bearer auth", () => {
    expect(parseBearer("Bearer abc123")).toBe("abc123");
  });

  it("compares tokens", () => {
    expect(constantTimeTokenEqual("a".repeat(32), "a".repeat(32))).toBe(true);
    expect(constantTimeTokenEqual("a".repeat(32), "b".repeat(32))).toBe(false);
    expect(constantTimeTokenEqual("short", "a".repeat(32))).toBe(false);
  });
});
