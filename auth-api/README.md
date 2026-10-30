# Jakhok OTP auth API

This is a small Node.js API for Vercel. It is separate from the L40S OCR app so login and email-code requests do not start an OCR GPU container.

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

The Resend sending domain for this project is `mail.neuroshift.dev`. After Resend shows it as verified, set `RESEND_FROM_EMAIL` to `Jakhok <verify@mail.neuroshift.dev>`.

## Vercel environment variables

Set these for Production and Preview as appropriate:

| Variable | Value |
| --- | --- |
| `FIREBASE_PROJECT_ID` | Firebase project ID |
| `FIREBASE_WEB_API_KEY` | Firebase Web API key |
| `FIREBASE_SERVICE_ACCOUNT_JSON` | Entire service-account JSON, stored only in Vercel |
| `RESEND_API_KEY` | Domain-scoped Resend Sending access key |
| `RESEND_FROM_EMAIL` | `Jakhok <verify@mail.neuroshift.dev>` after Resend verifies `mail.neuroshift.dev` |
| `OTP_HMAC_SECRET` | Random secret of at least 32 bytes |
| `AUTH_ALLOWED_ORIGINS` | Comma-separated Flutter web origins, such as `http://127.0.0.1:8080,http://localhost:8080,https://your-app-domain` |

Do not paste any of these secret values into chat or commit them to Git.

## Deploy and add your Cloudflare domain

1. Create a Vercel project with this folder as its project root (`auth-api`). The API routes are under `api/`, which Vercel deploys as Node.js Functions.
2. Add the environment variables above in Vercel Project Settings.
3. Deploy and confirm the Vercel URL responds to `POST /api/auth/session/status` with a JSON error when called without a token.
4. Add `auth.neuroshift.dev` to the Vercel project's Domains settings. Vercel will show the exact DNS record for that project.
5. In Cloudflare DNS, add the exact record Vercel provides for the `auth` hostname. Keep the existing records for `mail.neuroshift.dev`. Add Resend's SPF/DKIM records on the mail subdomain exactly as shown in Resend.
6. Set `AUTH_API_BASE_URL=https://auth.neuroshift.dev` when building the Flutter app.

Vercel's required CNAME value is project-specific; copy it from the Vercel domain screen rather than guessing it. If you have not chosen the actual domain yet, deploy first to the Vercel `.vercel.app` URL and add the custom domain later.

## Flutter build configuration

Add this compile-time value alongside the existing Firebase and OCR values:

```powershell
  --dart-define=AUTH_API_BASE_URL=https://auth.neuroshift.dev
```

For local Chrome development, the auth API accepts the current `localhost:8080` and `127.0.0.1:8080` origins by default. Add any deployed Flutter web hostname to `AUTH_ALLOWED_ORIGINS` before using it.

## Firestore cleanup

The records include an `expiresAt` timestamp. Configure Firestore TTL for `auth_challenges`, `auth_rate_limits`, and `auth_sessions` on that field so expired challenge and session metadata is removed automatically.

## Important API boundary

OTP gates the Flutter app and this API's session checks. The existing OCR API still uses its separate `x-api-key`; a key embedded in a Flutter build can be extracted. Before making the OCR API public, change it to verify Firebase ID tokens server-side as well.
