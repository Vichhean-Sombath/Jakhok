import {
  createChallenge,
  fail,
  getJson,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { idToken } = getJson(req);
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    if (!decoded.email) {
      return fail(res, 403, "This sign-in method does not have an email address.");
    }
    const challenge = await createChallenge({
      email: decoded.email,
      uid: decoded.uid,
      authTime: decoded.auth_time,
      mode: "firebase-session",
      req,
    });
    return res.status(200).json(challenge);
  } catch (error) {
    const message = String(error?.message || "");
    if (message.includes("wait before requesting")) {
      return fail(res, 429, message);
    }
    return fail(res, 401, "Sign in again, then request a new code.");
  }
}
