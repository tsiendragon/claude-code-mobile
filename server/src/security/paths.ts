import path from "node:path";
import os from "node:os";
import { realpath, stat } from "node:fs/promises";

export function expandHome(candidate: string): string {
  if (candidate === "~") return os.homedir();
  if (candidate.startsWith("~/")) return path.join(os.homedir(), candidate.slice(2));
  return candidate;
}

export async function assertAllowedCwd(
  cwd: string,
  allowedPaths: string[],
  options: { allowHiddenCwd: boolean }
): Promise<string> {
  const expandedCwd = expandHome(cwd);
  const expandedAllowedPaths = allowedPaths.map(expandHome);

  if (!path.isAbsolute(expandedCwd)) {
    throw new Error("PATH_NOT_ALLOWED: cwd must be absolute");
  }
  if (!options.allowHiddenCwd && hasHiddenPathSegment(expandedCwd)) {
    throw new Error("PATH_NOT_ALLOWED: hidden cwd segments are not allowed");
  }

  const realCwd = await realpath(expandedCwd);
  const cwdStat = await stat(realCwd);
  if (!cwdStat.isDirectory()) {
    throw new Error("PATH_NOT_ALLOWED: cwd must be a directory");
  }
  const realAllowed = await Promise.all(expandedAllowedPaths.map((allowed) => realpath(allowed)));
  const insideAllowedRoot = realAllowed.some((root) => isPathInside(realCwd, root));
  if (!insideAllowedRoot) {
    throw new Error("PATH_NOT_ALLOWED: cwd is outside allowed_paths");
  }
  return realCwd;
}

export function isPathInside(candidate: string, root: string): boolean {
  const relative = path.relative(root, candidate);
  return relative === "" || (!relative.startsWith("..") && !path.isAbsolute(relative));
}

function hasHiddenPathSegment(candidate: string): boolean {
  return candidate.split(path.sep).some((part) => part.startsWith(".") && part.length > 1);
}
