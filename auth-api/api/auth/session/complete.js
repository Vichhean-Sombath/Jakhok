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
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    const challengeId = decoded.otp_challenge_id;
    if (typeof challengeId !== "string") {
      return fail(res, 403, "Complete email verification before continuing.");
    }
    const { db } = firebase();
    const challenge = await db.collection("auth_challenges").doc(challengeId).get();
    if (
      !challenge.exists ||
      challenge.data().uid !== decoded.uid ||
      challenge.data().verified !== true
    ) {
      return fail(res, 403, "Complete email verification before continuing.");
    }
    await markVerifiedSession(decoded.uid, decoded.auth_time);
    return res.status(200).json({ verified: true });
  } catch (_) {
    return fail(res, 401, "Sign in again to continue.");
  }
}
