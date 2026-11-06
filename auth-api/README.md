# Jakhok OTP auth API

This is a small Node.js API for Vercel. It is separate from the L40S OCR app so login and email-code requests do not start an OCR GPU container.

## Local development

The API also has a Node standard-library development server. From this directory, run `npm run local`; it loads `.env.local` and binds only to `127.0.0.1:3000` (override the port with `LOCAL_AUTH_API_PORT`). Create `.env.local` from the required variables below, and set `LOCAL_ADMIN_OTP_BYPASS=1` only for local testing when needed. Do not commit `.env.local`.

The OTP bypass is active only when that variable is exactly `1`, `VERCEL` is absent, and `NODE_ENV` is not `production`. It checks the current Firebase Admin user for the boolean custom claim `ocr_local_otp_bypass`; a claim supplied only in a client token is ignored. Session status and the signed-in-user OTP start route return `{ "verified": true }` for an eligible account. A successful email/password login returns `{ "verified": true, "customToken": "..." }`; registration still uses email OTP. The bypass does not create a 30-day verified-session record, and removing the current custom claim revokes the bypass. The API does not assign this claim.

Run the offline checks with `npm test`.

## Routes

- `POST /api/auth/email/start` validates Firebase email/password credentials or creates the Firebase account, then emails a code.
- `POST /api/auth/otp/start` starts an OTP challenge for an already signed-in Firebase user (Google or a legacy email/password session).
- `POST /api/auth/otp/verify` checks the code. Email/password flows receive a Firebase custom token only after code verification.
- `POST /api/auth/session/status` checks whether the current Firebase sign-in session completed OTP.
- `POST /api/auth/session/complete` records the Firebase session created from a verified email/password challenge.

Codes are six digits, expire after 10 minutes, and allow at most five attempts. Sending is limited per email and IP. The server stores an HMAC of each code, not the code itself. Verified sessions are tracked against the Firebase `uid` and `auth_time`, so a later sign-in must complete OTP again.

## Firebase setup

1. Enable **Email/Password** and **Google** in Firebase Authentication.
2. Create a Firestore database for OTP challenge, rate-limit, and session records. Keep client Firestore rules closed; this API uses Firebase Admin.
3. Create a dedicated service account with only the Firebase Authentication Admin and Firestore access needed by this API. Store its JSON privately in Vercel as `FIREBASE_SERVICE_ACCOUNT_JSON`; never commit it or put it in Flutter.
4. Copy the Firebase Web API key and project ID into the Vercel environment variables listed below.

The API marks an email verified after the user proves control of that inbox with the code.

## Resend setup

In Resend, add a sending domain and publish the SPF/DKIM records it shows in your Cloudflare DNS. Wait for Resend to verify the domain. Create a **Sending access** API key restricted to that domain and add it to Vercel as `RESEND_API_KEY`.

The verified Resend sending domain for this project is `mails.neuroshift.dev`. After Resend shows it as verified, set `RESEND_FROM_EMAIL` to `Jakhok <no-reply@mails.neuroshift.dev>`. The production `RESEND_FROM_EMAIL` environment variable must match this address exactly.

## Vercel environment variables

Set these for Production and Preview as appropriate:

| Variable | Value |
| --- | --- |
| `FIREBASE_PROJECT_ID` | Firebase project ID |
| `FIREBASE_WEB_API_KEY` | Firebase Web API key |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Entire service-account JSON, stored only in Vercel |
| `RESEND_API_KEY` | Domain-scoped Resend Sending access key |
| `RESEND_FROM_EMAIL` | `Jakhok <no-reply@mails.neuroshift.dev>` after Resend verifies `mails.neuroshift.dev` |
| `OTP_HMAC_SECRET` | Random secret of at least 32 bytes |

Do not paste any of these secret values into chat or commit them to Git.

## Deploy and add your Cloudflare domain

1. Create a Vercel project with this folder as its project root (`auth-api`). The API routes are under `api/`, which Vercel deploys as Node.js Functions.
2. Add the environment variables above in Vercel Project Settings.
3. Deploy and confirm the Vercel URL responds to `POST /api/auth/session/status` with a JSON error when called without a token.
4. Add `auth.neuroshift.dev` to the Vercel project's Domains settings. Vercel will show the exact DNS record for that project.
5. In Cloudflare DNS, add the exact record Vercel provides for the `auth` hostname. Keep the existing records for `mails.neuroshift.dev`. Add Resend's SPF/DKIM records on the sending subdomain exactly as shown in Resend.
6. Set `AUTH_API_BASE_URL=https://auth.neuroshift.dev` when building the Flutter app.

Vercel's required CNAME value is project-specific; copy it from the Vercel domain screen rather than guessing it. If you have not chosen the actual domain yet, deploy first to the Vercel `.vercel.app` URL and add the custom domain later.

## Flutter build configuration

Add this compile-time value alongside the existing Firebase and OCR values:

```powershell
  --dart-define=AUTH_API_BASE_URL=https://auth.neuroshift.dev
```

The auth API allows browser requests from any origin. Firebase still requires the app's web domain to be listed under Authentication → Settings → Authorized domains for Google sign-in.

## Firestore cleanup

The records include an `expiresAt` timestamp. Configure Firestore TTL for `auth_challenges`, `auth_rate_limits`, and `auth_sessions` on that field so expired challenge and session metadata is removed automatically.

## Important API boundary

OTP gates the Flutter app and this API's session checks. The existing OCR API still uses its separate `x-api-key`; a key embedded in a Flutter build can be extracted. Before making the OCR API public, change it to verify Firebase ID tokens server-side as well.
