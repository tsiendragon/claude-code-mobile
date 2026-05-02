import path from "node:path";
import { realpath } from "node:fs/promises";

export async function assertAllowedCwd(
  cwd: string,
  allowedPaths: string[],
  options: { allowHiddenCwd: boolean }
): Promise<string> {
  if (!path.isAbsolute(cwd)) {
    throw new Error("PATH_NOT_ALLOWED: cwd must be absolute");
  }
  if (!options.allowHiddenCwd && hasHiddenPathSegment(cwd)) {
    throw new Error("PATH_NOT_ALLOWED: hidden cwd segments are not allowed");
  }

  const realCwd = await realpath(cwd);
  const realAllowed = await Promise.all(allowedPaths.map((allowed) => realpath(allowed)));
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
