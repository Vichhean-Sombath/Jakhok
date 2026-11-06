import assert from "node:assert/strict";
import test from "node:test";

import {
  canBypassEmailOtp,
  hasLocalAdminOtpBypassClaim,
  isLocalAdminOtpBypass,
  isLocalAdminOtpBypassEnabled,
} from "../api/_local_admin_bypass.js";

const localEnvironment = {
  LOCAL_ADMIN_OTP_BYPASS: "1",
  NODE_ENV: "development",
};

test("local bypass requires its exact opt-in and is denied in cloud or production", () => {
  assert.equal(isLocalAdminOtpBypassEnabled(localEnvironment), true);
  assert.equal(
    isLocalAdminOtpBypassEnabled({ ...localEnvironment, LOCAL_ADMIN_OTP_BYPASS: "true" }),
    false,
  );
  assert.equal(
    isLocalAdminOtpBypassEnabled({ ...localEnvironment, VERCEL: "1" }),
    false,
  );
  assert.equal(
    isLocalAdminOtpBypassEnabled({ ...localEnvironment, VERCEL: "" }),
    false,
  );
  assert.equal(
    isLocalAdminOtpBypassEnabled({ ...localEnvironment, NODE_ENV: "production" }),
    false,
  );
});

test("only the exact boolean local bypass custom claim grants eligibility", () => {
  assert.equal(hasLocalAdminOtpBypassClaim({ ocr_local_otp_bypass: true }), true);
  assert.equal(hasLocalAdminOtpBypassClaim({ ocr_local_otp_bypass: "true" }), false);
  assert.equal(hasLocalAdminOtpBypassClaim({ admin: true }), false);
  assert.equal(hasLocalAdminOtpBypassClaim(undefined), false);
});

test("authorization reads the current Admin SDK user, not decoded token claims", async () => {
  const lookups = [];
  const decoded = { uid: "user-123", ocr_local_otp_bypass: true };

  const revoked = await isLocalAdminOtpBypass(decoded, {
    env: localEnvironment,
    getUser: async (uid) => {
      lookups.push(uid);
      return { customClaims: {} };
    },
  });
  assert.equal(revoked, false);

  const currentlyAuthorized = await isLocalAdminOtpBypass(
    { uid: "user-123" },
    {
      env: localEnvironment,
      getUser: async (uid) => {
        lookups.push(uid);
        return { customClaims: { ocr_local_otp_bypass: true } };
      },
    },
  );
  assert.equal(currentlyAuthorized, true);
  assert.deepEqual(lookups, ["user-123", "user-123"]);
});

test("email OTP bypass applies to login only and only with the local claim", () => {
  const adminUser = { customClaims: { ocr_local_otp_bypass: true } };
  assert.equal(canBypassEmailOtp("login", adminUser, localEnvironment), true);
  assert.equal(canBypassEmailOtp("register", adminUser, localEnvironment), false);
  assert.equal(canBypassEmailOtp("login", { customClaims: {} }, localEnvironment), false);
  assert.equal(
    canBypassEmailOtp("login", adminUser, { ...localEnvironment, VERCEL: "1" }),
    false,
  );
});

test("disabled or cloud bypass does not query Firebase Admin", async () => {
  let lookupCount = 0;
  for (const env of [
    { ...localEnvironment, LOCAL_ADMIN_OTP_BYPASS: "0" },
    { ...localEnvironment, VERCEL: "1" },
    { ...localEnvironment, NODE_ENV: "production" },
  ]) {
    assert.equal(
      await isLocalAdminOtpBypass({ uid: "user-123" }, {
        env,
        getUser: async () => {
          lookupCount += 1;
          return { customClaims: { ocr_local_otp_bypass: true } };
        },
      }),
      false,
    );
  }
  assert.equal(lookupCount, 0);
});
