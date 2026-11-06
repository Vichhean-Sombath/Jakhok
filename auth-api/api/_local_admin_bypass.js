export const LOCAL_ADMIN_BYPASS_CLAIM = "ocr_local_otp_bypass";

export function isLocalAdminOtpBypassEnabled(env = process.env) {
  return (
    env.LOCAL_ADMIN_OTP_BYPASS === "1" &&
    typeof env.VERCEL === "undefined" &&
    env.NODE_ENV !== "production"
  );
}

export function hasLocalAdminOtpBypassClaim(customClaims) {
  return customClaims?.[LOCAL_ADMIN_BYPASS_CLAIM] === true;
}

export function canBypassEmailOtp(mode, user, env = process.env) {
  return (
    mode === "login" &&
    isLocalAdminOtpBypassEnabled(env) &&
    hasLocalAdminOtpBypassClaim(user?.customClaims)
  );
}

export async function isLocalAdminOtpBypass(
  decoded,
  { env = process.env, getUser } = {},
) {
  if (
    !isLocalAdminOtpBypassEnabled(env) ||
    typeof decoded?.uid !== "string" ||
    decoded.uid.length === 0 ||
    typeof getUser !== "function"
  ) {
    return false;
  }

  // Deliberately ignore decoded token claims: getUser returns current Admin SDK
  // state, so removing the claim immediately revokes this local-only bypass.
  const user = await getUser(decoded.uid);
  return hasLocalAdminOtpBypassClaim(user?.customClaims);
}
