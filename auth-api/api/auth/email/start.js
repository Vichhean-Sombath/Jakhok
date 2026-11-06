import {
  createChallenge,
  fail,
  firebasePasswordAuth,
  createFirebaseCustomToken,
  getFirebaseUser,
  getJson,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";
import {
  canBypassEmailOtp,
  isLocalAdminOtpBypassEnabled,
} from "../../_local_admin_bypass.js";

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { email: rawEmail, password, mode } = getJson(req);
  const email = typeof rawEmail === "string" ? rawEmail.trim().toLowerCase() : "";
  if (
    !email.includes("@") ||
    typeof password !== "string" ||
    password.length < 6 ||
    !["register", "login"].includes(mode)
  ) {
    return fail(res, 400, "Enter a valid email and password.");
  }

  let stage = "firebase_password_auth";
  try {
    let result;
    if (mode === "register") {
      try {
        result = await firebasePasswordAuth("signUp", email, password);
      } catch (_) {
        // Let an unverified account retry registration and request another code.
        result = await firebasePasswordAuth("signInWithPassword", email, password);
      }
    } else {
      result = await firebasePasswordAuth("signInWithPassword", email, password);
    }
    stage = "verify_firebase_id_token";
    const decoded = await verifyFirebaseIdToken(result.idToken);
    if (mode === "login" && isLocalAdminOtpBypassEnabled()) {
      stage = "check_local_admin_bypass";
      const user = await getFirebaseUser(decoded.uid);
      if (canBypassEmailOtp(mode, user)) {
        stage = "create_local_admin_custom_token";
        const customToken = await createFirebaseCustomToken(decoded.uid);
        return res.status(200).json({ verified: true, customToken });
      }
    }
    stage = "create_otp_challenge";
    const challenge = await createChallenge({
      email: decoded.email || email,
      uid: decoded.uid,
      authTime: decoded.auth_time,
      mode: mode === "register" ? "email-register" : "email-login",
      req,
    });
    return res.status(200).json(challenge);
  } catch (error) {
    const diagnostic = {
      stage: error?.authStage || stage,
      errorName:
        typeof error?.name === "string" && /^[A-Za-z0-9_]+$/.test(error.name)
          ? error.name
          : "Error",
      code: (() => {
        const code = error?.code;
        if (typeof code === "number" && Number.isInteger(code)) {
          return `GRPC_${code}`;
        }
        return typeof code === "string" && /^[A-Za-z0-9_/-]{1,80}$/.test(code)
          ? code
          : undefined;
      })(),
      statusCode: Number.isInteger(error?.statusCode)
        ? error.statusCode
        : undefined,
    };
    console.error("[auth/email/start] failed", diagnostic);
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
    if (
      error?.authStage ||
      ["check_local_admin_bypass", "create_local_admin_custom_token"].includes(stage)
    ) {
      return fail(res, 503, "We could not start sign-in right now. Try again later.");
    }
    // Do not reveal whether the address is registered or whether its password matched.
    return fail(res, 400, "We could not start sign-in. Check the details and try again.");
  }
}
