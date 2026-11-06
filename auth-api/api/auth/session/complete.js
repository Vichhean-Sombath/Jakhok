import {
  fail,
  firebase,
  getJson,
  markVerifiedSession,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { idToken } = getJson(req);
  let stage = "verify_firebase_id_token";
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    const challengeId = decoded.otp_challenge_id;
    if (typeof challengeId !== "string") {
      return fail(res, 403, "Complete email verification before continuing.");
    }
    stage = "read_verified_challenge";
    const { db } = firebase();
    const challenge = await db.collection("auth_challenges").doc(challengeId).get();
    if (
      !challenge.exists ||
      challenge.data().uid !== decoded.uid ||
      challenge.data().verified !== true
    ) {
      return fail(res, 403, "Complete email verification before continuing.");
    }
    stage = "mark_verified_session";
    await markVerifiedSession(decoded.uid, decoded.auth_time);
    return res.status(200).json({ verified: true });
  } catch (error) {
    const diagnostic = {
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
    console.error("[auth/session/complete] failed", diagnostic);
    return fail(res, 401, "Sign in again to continue.");
  }
}
