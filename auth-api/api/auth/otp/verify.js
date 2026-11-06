import {
  completeOtpChallenge,
  createFirebaseCustomToken,
  fail,
  getFirebaseUser,
  getJson,
  markEmailVerified,
  markVerifiedSession,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";

function authDiagnostic(error, stage) {
  return {
    stage,
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
}

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { challengeId, code, idToken } = getJson(req);
  let decoded;
  if (typeof idToken === "string") {
    try {
      decoded = await verifyFirebaseIdToken(idToken);
    } catch (error) {
      console.error(
        "[auth/otp/verify] failed",
        authDiagnostic(error, "verify_firebase_id_token"),
      );
      return fail(res, 401, "Sign in again, then enter the latest code.");
    }
  }

  let stage = "complete_otp_challenge";
  try {
    const challenge = await completeOtpChallenge(
      challengeId,
      code,
      decoded ? { uid: decoded.uid, authTime: decoded.auth_time } : null,
    );
    if (!challenge.ok) return fail(res, 400, "That code is incorrect. Try again.");

    if (challenge.mode === "firebase-session") {
      if (
        !decoded ||
        decoded.uid !== challenge.uid ||
        decoded.auth_time !== challenge.authTime
      ) {
        return fail(res, 401, "Your sign-in session changed. Request a new code.");
      }
      stage = "get_firebase_user";
      const user = await getFirebaseUser(decoded.uid);
      if (!user.emailVerified) {
        stage = "mark_email_verified";
        await markEmailVerified(decoded.uid);
      }
      stage = "mark_verified_session";
      await markVerifiedSession(decoded.uid, decoded.auth_time);
      return res.status(200).json({ verified: true });
    }

    stage = "get_firebase_user";
    const user = await getFirebaseUser(challenge.uid);
    if (!user.emailVerified) {
      stage = "mark_email_verified";
      await markEmailVerified(challenge.uid);
    }
    stage = "create_firebase_custom_token";
    const customToken = await createFirebaseCustomToken(challenge.uid, {
      otp_challenge_id: challengeId,
    });
    return res.status(200).json({ verified: true, customToken });
  } catch (error) {
    const message = String(error?.message || "");
    console.error("[auth/otp/verify] failed", authDiagnostic(error, stage));
    return fail(
      res,
      message.includes("Sign in again") ? 401 : 400,
      message.includes("Sign in again")
        ? message
        : "That code is invalid or expired. Request a new one.",
    );
  }
}
