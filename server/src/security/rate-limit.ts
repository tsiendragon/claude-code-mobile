type Bucket = {
  tokens: number;
  updatedAt: number;
};

export class TokenBucketRateLimiter {
  private readonly buckets = new Map<string, Bucket>();

  constructor(
    private readonly ratePerSecond: number,
    private readonly burst: number,
    private readonly now = () => Date.now()
  ) {}

  allow(key: string): boolean {
    const now = this.now();
    const bucket = this.buckets.get(key) ?? { tokens: this.burst, updatedAt: now };
    const elapsedSeconds = Math.max(0, now - bucket.updatedAt) / 1000;
    bucket.tokens = Math.min(this.burst, bucket.tokens + elapsedSeconds * this.ratePerSecond);
    bucket.updatedAt = now;
    if (bucket.tokens < 1) {
      this.buckets.set(key, bucket);
      return false;
    }
    bucket.tokens -= 1;
    this.buckets.set(key, bucket);
    return true;
  }
}

export class AuthFailureTracker {
  private readonly failures = new Map<string, { count: number; blockedUntil?: number }>();

  constructor(
    private readonly maxFailures = 5,
    private readonly cooldownMs = 30 * 60 * 1000,
    private readonly now = () => Date.now()
  ) {}

  isBlocked(key: string): boolean {
    const failure = this.failures.get(key);
    return Boolean(failure?.blockedUntil && failure.blockedUntil > this.now());
  }

  recordFailure(key: string) {
    const current = this.failures.get(key) ?? { count: 0 };
    current.count += 1;
    if (current.count >= this.maxFailures) {
      current.blockedUntil = this.now() + this.cooldownMs;
    }
    this.failures.set(key, current);
  }

  clear(key: string) {
    this.failures.delete(key);
  }
}
