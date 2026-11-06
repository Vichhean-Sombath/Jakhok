const HOUR_MS = 60 * 60 * 1000;
const DAY_MS = 24 * HOUR_MS;

export const OTP_RATE_LIMITS = Object.freeze({
  email: Object.freeze({ limit: 5, intervalMs: HOUR_MS, minGapMs: 60 * 1000 }),
  ip: Object.freeze({ limit: 30, intervalMs: HOUR_MS, minGapMs: 10 * 1000 }),
});

export function evaluateRateLimit(row, now, { limit, intervalMs, minGapMs }) {
  const windowStart = row.windowStart?.toMillis?.() || 0;
  const count = now - windowStart < intervalMs ? row.count || 0 : 0;
  const lastSent = row.lastSent?.toMillis?.() || 0;

  const windowRetryMs =
    count >= limit ? Math.max(0, windowStart + intervalMs - now) : 0;
  const gapRetryMs =
    lastSent && now - lastSent < minGapMs
      ? Math.max(0, minGapMs - (now - lastSent))
      : 0;
  const retryAfterMs = Math.max(windowRetryMs, gapRetryMs);

  return {
    allowed: retryAfterMs === 0,
    count,
    windowStart,
    retryAfterMs,
  };
}

export async function transactOtpRateLimits({
  db,
  emailRef,
  ipRef,
  now,
  timestampFromMillis,
}) {
  const outcome = await db.runTransaction(async (tx) => {
    const emailSnap = await tx.get(emailRef);
    const ipSnap = await tx.get(ipRef);
    const emailRow = emailSnap.exists ? emailSnap.data() : {};
    const ipRow = ipSnap.exists ? ipSnap.data() : {};
    const emailDecision = evaluateRateLimit(
      emailRow,
      now,
      OTP_RATE_LIMITS.email,
    );
    const ipDecision = evaluateRateLimit(ipRow, now, OTP_RATE_LIMITS.ip);
    const retryAfterMs = Math.max(
      emailDecision.retryAfterMs,
      ipDecision.retryAfterMs,
    );

    if (retryAfterMs > 0) {
      return {
        allowed: false,
        retryAfterSeconds: Math.ceil(retryAfterMs / 1000),
      };
    }

    for (const [ref, decision] of [
      [emailRef, emailDecision],
      [ipRef, ipDecision],
    ]) {
      const nextWindowStart = decision.count === 0 ? now : decision.windowStart;
      tx.set(ref, {
        windowStart: timestampFromMillis(nextWindowStart),
        count: decision.count + 1,
        lastSent: timestampFromMillis(now),
        expiresAt: timestampFromMillis(now + DAY_MS),
      });
    }

    return { allowed: true };
  });

  if (!outcome.allowed) {
    const error = new Error("Please wait before requesting another code.");
    error.name = "RateLimitError";
    error.code = "OTP_RATE_LIMITED";
    error.retryAfterSeconds = outcome.retryAfterSeconds;
    throw error;
  }
}
