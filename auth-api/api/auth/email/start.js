import {
  createChallenge,
  fail,
  firebasePasswordAuth,
  getJson,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";

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
    const message = String(error?.message || "");
    const diagnostic = {
      stage: error?.authStage || stage,
      errorName:
        typeof error?.name === "string" && /^[A-Za-z0-9_]+$/.test(error.name)
          ? error.name
          : "Error",
      code:
        typeof error?.code === "string" && /^[A-Za-z0-9_/-]{1,80}$/.test(error.code)
          ? error.code
          : undefined,
      statusCode: Number.isInteger(error?.statusCode)
        ? error.statusCode
        : undefined,
    };
    console.error("[auth/email/start] failed", diagnostic);
    if (message.includes("wait before requesting")) {
      return fail(res, 429, message);
    }
    // Do not reveal whether the address is registered or whether its password matched.
    return fail(res, 400, "We could not start sign-in. Check the details and try again.");
  }
}
