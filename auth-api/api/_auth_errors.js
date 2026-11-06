const INVALID_FIREBASE_ID_TOKEN_CODES = new Set([
  "auth/argument-error",
  "auth/id-token-expired",
  "auth/id-token-revoked",
  "auth/invalid-argument",
  "auth/invalid-id-token",
]);

export function invalidFirebaseIdTokenError() {
  const error = new Error("Sign in again, then request a new code.");
  error.code = "auth/invalid-id-token";
  return error;
}

export function assertFirebaseIdTokenShape(idToken) {
  if (typeof idToken !== "string" || idToken.length < 40) {
    throw invalidFirebaseIdTokenError();
  }
}

export function isInvalidFirebaseIdTokenError(error) {
  return INVALID_FIREBASE_ID_TOKEN_CODES.has(error?.code);
}
