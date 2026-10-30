import crypto from "node:crypto";
import { getApps, initializeApp, cert } from "firebase-admin/app";
import { getAuth } from "firebase-admin/auth";
import { FieldValue, Timestamp, getFirestore } from "firebase-admin/firestore";
import { Resend } from "resend";

const CHALLENGE_TTL_MS = 10 * 60 * 1000;
const SESSION_TTL_MS = 30 * 24 * 60 * 60 * 1000;
const MAX_OTP_ATTEMPTS = 5;

function requiredEnv(name) {
  const value = process.env[name];
  if (!value) throw new Error(`Missing server configuration: ${name}`);
  return value;
}

export function firebase() {
  if (!getApps().length) {
    const serviceAccount = JSON.parse(
      requiredEnv("FIREBASE_SERVICE_ACCOUNT_JSON"),
    );
    initializeApp({
      credential: cert(serviceAccount),
      projectId: process.env.FIREBASE_PROJECT_ID || serviceAccount.project_id,
    });
  }
  return { auth: getAuth(), db: getFirestore() };
}

export function prepareRequest(req, res) {
  const allowed = (process.env.AUTH_ALLOWED_ORIGINS ||
    "http://localhost:8080,http://127.0.0.1:8080")
    .split(",")
    .map((value) => value.trim())
    .filter(Boolean);
  const origin = req.headers.origin;
  if (origin && !allowed.includes(origin)) {
    res.status(403).json({ error: "Origin is not allowed." });
    return false;
  }
  if (origin) {
    res.setHeader("Access-Control-Allow-Origin", origin);
    res.setHeader("Vary", "Origin");
  }
  res.setHeader("Access-Control-Allow-Methods", "POST, OPTIONS");
  res.setHeader("Access-Control-Allow-Headers", "Content-Type, Authorization");
  res.setHeader("Cache-Control", "no-store");
  if (req.method === "OPTIONS") {
    res.status(204).end();
    return false;
  }
  if (req.method !== "POST") {
    res.status(405).json({ error: "Use POST for this endpoint." });
    return false;
  }
  return true;
}

export function getJson(req) {
  return req.body && typeof req.body === "object" ? req.body : {};
}

export function fail(res, status, message) {
  return res.status(status).json({ error: message });
}

export function randomId() {
  return crypto.randomUUID();
}

function digest(value) {
  return crypto.createHash("sha256").update(value).digest("hex");
}

export function hashOtp(challengeId, code) {
  return crypto
    .createHmac("sha256", requiredEnv("OTP_HMAC_SECRET"))
    .update(`${challengeId}:${code}`)
    .digest("hex");
}

function safeEqualHex(left, right) {
  const a = Buffer.from(left, "hex");
  const b = Buffer.from(right, "hex");
  return a.length === b.length && crypto.timingSafeEqual(a, b);
}

export async function applyRateLimits(email, req) {
  const { db } = firebase();
  const emailKey = digest(`email:${email}`);
  const forwarded = req.headers["x-forwarded-for"];
  const ip = typeof forwarded === "string" ? forwarded.split(",")[0].trim() : "unknown";
  const ipKey = digest(`ip:${ip}`);
  const now = Date.now();

  async function consume(key, limit, intervalMs, minGapMs) {
    const ref = db.collection("auth_rate_limits").doc(key);
    return db.runTransaction(async (tx) => {
      const snap = await tx.get(ref);
      const row = snap.exists ? snap.data() : {};
      const windowStart = row.windowStart?.toMillis?.() || 0;
      const count = now - windowStart < intervalMs ? row.count || 0 : 0;
      const lastSent = row.lastSent?.toMillis?.() || 0;
      if (count >= limit || (lastSent && now - lastSent < minGapMs)) {
        return false;
      }
      const nextWindowStart = count === 0 ? now : windowStart;
      tx.set(ref, {
        windowStart: Timestamp.fromMillis(nextWindowStart),
        count: count + 1,
        lastSent: Timestamp.fromMillis(now),
        expiresAt: Timestamp.fromMillis(now + 24 * 60 * 60 * 1000),
      });
      return true;
    });
  }

  const emailAllowed = await consume(emailKey, 5, 60 * 60 * 1000, 60 * 1000);
  const ipAllowed = await consume(ipKey, 30, 60 * 60 * 1000, 10 * 1000);
  if (!emailAllowed || !ipAllowed) {
    throw new Error("Please wait before requesting another code.");
  }
}

export async function createChallenge({ email, uid, authTime, mode, req }) {
  await applyRateLimits(email, req);
  const { db } = firebase();
  const challengeId = randomId();
  const code = crypto.randomInt(0, 1_000_000).toString().padStart(6, "0");
  const expiresAt = Date.now() + CHALLENGE_TTL_MS;
  const ref = db.collection("auth_challenges").doc(challengeId);
  await ref.create({
    email,
    uid,
    authTime,
    mode,
    codeHash: hashOtp(challengeId, code),
    attempts: 0,
    verified: false,
    used: false,
    createdAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis(expiresAt),
  });

  let result;
  try {
    const resend = new Resend(requiredEnv("RESEND_API_KEY"));
    result = await resend.emails.send({
      from: requiredEnv("RESEND_FROM_EMAIL"),
      to: [email],
      subject: "Your Jakhok sign-in code",
      text: `Your Jakhok verification code is ${code}. It expires in 10 minutes. If you did not request it, you can ignore this email.`,
      html: `<div style="font-family:Arial,sans-serif;max-width:480px;margin:auto;color:#111827"><h1 style="font-size:22px">Verify your Jakhok sign-in</h1><p>Enter this code in the app. It expires in 10 minutes.</p><p style="font-size:32px;font-weight:700;letter-spacing:8px;color:#1769ff">${code}</p><p style="color:#667085">If you did not request this code, you can ignore this email.</p></div>`,
    });
  } catch (_) {
    await ref.delete();
    throw new Error("Email provider could not send the verification code.");
  }
  if (result.error) {
    await ref.delete();
    throw new Error("Email provider could not send the verification code.");
  }
  return { challengeId, expiresInSeconds: CHALLENGE_TTL_MS / 1000 };
}

export async function verifyFirebaseIdToken(idToken) {
  if (typeof idToken !== "string" || idToken.length < 40) {
    throw new Error("Sign in again, then request a new code.");
  }
  const { auth } = firebase();
  return auth.verifyIdToken(idToken, true);
}

export async function completeOtpChallenge(challengeId, code, expectedSession = null) {
  if (typeof challengeId !== "string" || typeof code !== "string" || !/^\d{6}$/.test(code)) {
    throw new Error("That code is invalid or expired.");
  }
  const { db } = firebase();
  const ref = db.collection("auth_challenges").doc(challengeId);
  return db.runTransaction(async (tx) => {
    const snap = await tx.get(ref);
    if (!snap.exists) throw new Error("That code is invalid or expired.");
    const row = snap.data();
    if (row.mode === "firebase-session" && !expectedSession) {
      throw new Error("Sign in again, then enter the latest code.");
    }
    if (
      expectedSession &&
      (row.uid !== expectedSession.uid || row.authTime !== expectedSession.authTime)
    ) {
      throw new Error("Sign in again, then enter the latest code.");
    }
    const expected = row.codeHash || "";
    const supplied = hashOtp(challengeId, code);
    const matches = safeEqualHex(expected, supplied);
    const expired = !row.expiresAt || row.expiresAt.toMillis() <= Date.now();
    if (row.used || row.attempts >= MAX_OTP_ATTEMPTS || expired) {
      throw new Error("That code is invalid or expired.");
    }
    if (!matches) {
      tx.update(ref, { attempts: FieldValue.increment(1) });
      return { ok: false };
    }
    tx.update(ref, { used: true, verified: true, verifiedAt: FieldValue.serverTimestamp() });
    return { ok: true, ...row };
  });
}

export async function markVerifiedSession(uid, authTime) {
  const { db } = firebase();
  const key = digest(`${uid}:${authTime}`);
  await db.collection("auth_sessions").doc(key).set({
    uid,
    authTime,
    verifiedAt: FieldValue.serverTimestamp(),
    expiresAt: Timestamp.fromMillis(Date.now() + SESSION_TTL_MS),
  });
}

export async function isVerifiedSession(uid, authTime) {
  const { db } = firebase();
  const key = digest(`${uid}:${authTime}`);
  const snap = await db.collection("auth_sessions").doc(key).get();
  return snap.exists && snap.data().expiresAt?.toMillis?.() > Date.now();
}

export function firebaseRestUrl(action) {
  return `https://identitytoolkit.googleapis.com/v1/accounts:${action}?key=${requiredEnv("FIREBASE_WEB_API_KEY")}`;
}

export async function firebasePasswordAuth(action, email, password) {
  const response = await fetch(firebaseRestUrl(action), {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });
  const result = await response.json().catch(() => ({}));
  if (!response.ok) throw new Error("Email or password could not be verified.");
  return result;
}

export async function createFirebaseCustomToken(uid, claims) {
  const { auth } = firebase();
  return auth.createCustomToken(uid, claims);
}

export async function getFirebaseUser(uid) {
  const { auth } = firebase();
  return auth.getUser(uid);
}

export async function markEmailVerified(uid) {
  const { auth } = firebase();
  await auth.updateUser(uid, { emailVerified: true });
}
