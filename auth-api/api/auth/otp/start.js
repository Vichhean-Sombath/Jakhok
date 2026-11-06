import {
  createChallenge,
  fail,
  getFirebaseUser,
  getJson,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";
import { isInvalidFirebaseIdTokenError } from "../../_auth_errors.js";
import { isLocalAdminOtpBypass } from "../../_local_admin_bypass.js";

function safeDiagnosticLabel(value, fallback) {
  return typeof value === "string" && /^[A-Za-z0-9_/-]{1,80}$/.test(value)
    ? value
    : fallback;
}

function authDiagnostic(error, stage) {
  return {
    stage: safeDiagnosticLabel(error?.authStage, stage),
    errorName: safeDiagnosticLabel(error?.name, "Error"),
    code: safeDiagnosticLabel(error?.code, undefined),
    statusCode: Number.isInteger(error?.statusCode)
      ? error.statusCode
      : undefined,
  };
}

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { idToken } = getJson(req);
  let stage = "verify_firebase_id_token";
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    stage = "check_local_admin_bypass";
    if (
      await isLocalAdminOtpBypass(decoded, { getUser: getFirebaseUser })
    ) {
      return res.status(200).json({ verified: true });
    }
    if (!decoded.email) {
      return fail(res, 403, "This sign-in method does not have an email address.");
    }
    stage = "create_otp_challenge";
    const challenge = await createChallenge({
      email: decoded.email,
      uid: decoded.uid,
      authTime: decoded.auth_time,
      mode: "firebase-session",
      req,
    });
    return res.status(200).json(challenge);
  } catch (error) {
    console.error("[auth/otp/start] failed", authDiagnostic(error, stage));
    if (
      error?.authStage === "rate_limit" &&
      error?.code === "OTP_RATE_LIMITED" &&
      Number.isSafeInteger(error?.retryAfterSeconds) &&
      error.retryAfterSeconds > 0
    ) {
      const retryAfterSeconds = error.retryAfterSeconds;
      res.setHeader("Retry-After", String(retryAfterSeconds));
      return res.status(429).json({
        error: "Please wait before requesting another code.",
        retryAfterSeconds,
      });
    }
    if (isInvalidFirebaseIdTokenError(error)) {
      return fail(res, 401, "Sign in again, then request a new code.");
    }
    return fail(res, 503, "We could not start sign-in right now. Try again later.");
  }
}
