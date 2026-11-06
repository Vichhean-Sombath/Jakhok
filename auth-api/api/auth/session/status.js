import {
  fail,
  getFirebaseUser,
  getJson,
  isVerifiedSession,
  prepareRequest,
  verifyFirebaseIdToken,
} from "../../_server.js";
import { isLocalAdminOtpBypass } from "../../_local_admin_bypass.js";

export default async function handler(req, res) {
  if (!prepareRequest(req, res)) return;
  const { idToken } = getJson(req);
  try {
    const decoded = await verifyFirebaseIdToken(idToken);
    if (
      await isLocalAdminOtpBypass(decoded, { getUser: getFirebaseUser })
    ) {
      return res.status(200).json({ verified: true });
    }
    const verified = await isVerifiedSession(decoded.uid, decoded.auth_time);
    return res.status(200).json({ verified });
  } catch (_) {
    return fail(res, 401, "Sign in again to continue.");
  }
}
