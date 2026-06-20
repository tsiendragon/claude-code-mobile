import { mkdtemp, realpath } from "node:fs/promises";
import os from "node:os";
import path from "node:path";
import { describe, expect, it } from "vitest";
import { assertAllowedCwd } from "../src/security/paths.js";

describe("assertAllowedCwd", () => {
  it("allows cwd when another configured allowed path does not exist", async () => {
    const root = await mkdtemp(path.join(os.tmpdir(), "ccm-paths-"));
    const missing = path.join(root, "missing");
    const resolvedRoot = await realpath(root);

    await expect(assertAllowedCwd(root, [root, missing], { allowHiddenCwd: false }))
      .resolves
      .toBe(resolvedRoot);
  });
});
