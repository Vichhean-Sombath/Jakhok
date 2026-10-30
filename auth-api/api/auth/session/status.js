import {
  fail,
  getJson,
  isVerifiedSession,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { idToken } = getJson(req);
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    const verified = await isVerifiedSession(decoded.uid, decoded.auth_time);
    return res.status(200).json({ verified });
  } catch (_) {
    return fail(res, 401, "Sign in again to continue.");
  }
}
