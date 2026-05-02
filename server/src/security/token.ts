import { timingSafeEqual } from "node:crypto";

export function parseBearer(value: unknown): string | undefined {
  if (typeof value !== "string") return undefined;
  const match = /^Bearer\s+(.+)$/i.exec(value.trim());
  return match?.[1];
}

export function constantTimeTokenEqual(actual: string, expected: string): boolean {
  const actualBuffer = Buffer.from(actual, "utf8");
  const expectedBuffer = Buffer.from(expected, "utf8");
  if (actualBuffer.length !== expectedBuffer.length) {
    const padded = Buffer.alloc(expectedBuffer.length);
    actualBuffer.copy(padded, 0, 0, Math.min(actualBuffer.length, padded.length));
    timingSafeEqual(padded, expectedBuffer);
    return false;
  }
  return timingSafeEqual(actualBuffer, expectedBuffer);
}

export function redactToken(token: string): string {
  if (token.length <= 8) return "<redacted>";
  return `${token.slice(0, 4)}...${token.slice(-4)}`;
}
