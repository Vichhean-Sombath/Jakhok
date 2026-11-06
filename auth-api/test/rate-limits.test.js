import assert from "node:assert/strict";
import test from "node:test";

import {
  evaluateRateLimit,
  OTP_RATE_LIMITS,
  transactOtpRateLimits,
} from "../api/_rate_limits.js";
import {
  assertFirebaseIdTokenShape,
  isInvalidFirebaseIdTokenError,
} from "../api/_auth_errors.js";

const HOUR_MS = 60 * 60 * 1000;
const NOW = 1_800_000_000_000;

function timestamp(millis) {
  return { toMillis: () => millis };
}

class FakeFirestore {
  constructor(rows = {}) {
    this.rows = new Map(Object.entries(rows));
    this.transactionCount = 0;
    this.reads = [];
    this.writes = [];
  }

  async runTransaction(callback) {
    this.transactionCount += 1;
    const pendingWrites = [];
    const tx = {
      get: async (ref) => {
        this.reads.push(ref.id);
        const row = this.rows.get(ref.id);
        return { exists: row !== undefined, data: () => row };
      },
      set: (ref, row) => pendingWrites.push([ref.id, row]),
    };
    const result = await callback(tx);
    for (const [id, row] of pendingWrites) {
      this.rows.set(id, row);
      this.writes.push(id);
    }
    return result;
  }
}

function runLimits(db, now = NOW) {
  return transactOtpRateLimits({
    db,
    emailRef: { id: "email" },
    ipRef: { id: "ip" },
    now,
    timestampFromMillis: timestamp,
  });
}

test("evaluates hourly count and minimum-gap limits", () => {
  const fresh = evaluateRateLimit({}, NOW, OTP_RATE_LIMITS.email);
  assert.equal(fresh.allowed, true);
  assert.equal(fresh.count, 0);

  const countLimited = evaluateRateLimit(
    {
      windowStart: timestamp(NOW - HOUR_MS + 12_400),
      count: 5,
      lastSent: timestamp(NOW - 120_000),
    },
    NOW,
    OTP_RATE_LIMITS.email,
  );
  assert.equal(countLimited.allowed, false);
  assert.equal(countLimited.retryAfterMs, 12_400);

  const gapLimited = evaluateRateLimit(
    {
      windowStart: timestamp(NOW - 120_000),
      count: 1,
      lastSent: timestamp(NOW - 57_500),
    },
    NOW,
    OTP_RATE_LIMITS.email,
  );
  assert.equal(gapLimited.allowed, false);
  assert.equal(gapLimited.retryAfterMs, 2_500);
});

test("classifies missing and short Firebase ID tokens as authentication failures", () => {
  for (const idToken of [undefined, null, "", "too-short"]) {
    assert.throws(
      () => assertFirebaseIdTokenShape(idToken),
      (error) => {
        assert.equal(error.code, "auth/invalid-id-token");
        assert.equal(isInvalidFirebaseIdTokenError(error), true);
        return true;
      },
    );
  }

  assert.doesNotThrow(() => assertFirebaseIdTokenShape("x".repeat(40)));
  assert.equal(
    isInvalidFirebaseIdTokenError({ code: "auth/invalid-credential" }),
    false,
  );
});

test("reads and writes both counters in one transaction when both pass", async () => {
  const db = new FakeFirestore();

  await runLimits(db);

  assert.equal(db.transactionCount, 1);
  assert.deepEqual(db.reads, ["email", "ip"]);
  assert.deepEqual(db.writes, ["email", "ip"]);
  assert.equal(db.rows.get("email").count, 1);
  assert.equal(db.rows.get("ip").count, 1);
  assert.equal(db.rows.get("email").windowStart.toMillis(), NOW);
  assert.equal(db.rows.get("email").lastSent.toMillis(), NOW);
});

test("does not consume either counter when the email limit rejects", async () => {
  const db = new FakeFirestore({
    email: {
      windowStart: timestamp(NOW - HOUR_MS + 1_200),
      count: 5,
      lastSent: timestamp(NOW - 120_000),
    },
  });

  await assert.rejects(runLimits(db), (error) => {
    assert.equal(error.name, "RateLimitError");
    assert.equal(error.retryAfterSeconds, 2);
    return true;
  });

  assert.equal(db.transactionCount, 1);
  assert.deepEqual(db.reads, ["email", "ip"]);
  assert.deepEqual(db.writes, []);
  assert.equal(db.rows.get("email").count, 5);
  assert.equal(db.rows.has("ip"), false);
});

test("does not consume either counter when the IP limit rejects and reports the longest wait", async () => {
  const db = new FakeFirestore({
    email: {
      windowStart: timestamp(NOW - 90_000),
      count: 4,
      lastSent: timestamp(NOW - 70_000),
    },
    ip: {
      windowStart: timestamp(NOW - HOUR_MS + 8_700),
      count: 30,
      lastSent: timestamp(NOW - 20_000),
    },
  });

  await assert.rejects(runLimits(db), (error) => {
    assert.equal(error.retryAfterSeconds, 9);
    return true;
  });

  assert.equal(db.transactionCount, 1);
  assert.deepEqual(db.writes, []);
  assert.equal(db.rows.get("email").count, 4);
  assert.equal(db.rows.get("ip").count, 30);
});
