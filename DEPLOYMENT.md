# Netra CI/CD and deployment

## What the pipeline does

`.github/workflows/ci-cd.yml` runs on pull requests and pushes to `main`:

- Rejects tracked `.env` files and common credential patterns.
- Runs the auth API's Node.js tests and high-severity dependency audit.
- Formats, analyzes, tests, and builds the Flutter web app.
- Runs the Python OCR unit tests.
- Packages a production Flutter web artifact on `main`.
- Deploys `auth-api` to Vercel on a successful `main` build, then checks `https://auth.neuroshift.dev`.

Pull requests never deploy. Modal deployment is intentionally not part of this pipeline.

## Local environment files

Real environment files stay on your machine and are ignored by Git. Do not move them into Vercel or GitHub manually unless a step below asks for a named variable.

Examples to copy:

- `auth-api/.env.example` → `auth-api/.env.local`
- `KhmerOCR-Flutter-Working/.env.example` → `KhmerOCR-Flutter-Working/.env.local`
- `.env.modal-client.example` → `.env.modal-client`

Run the local secret check with `python scripts/check_secrets.py`. It prints only filenames, line numbers, and rule names—not secret values.

## One-time GitHub setup

Add these repository secrets under **Settings → Secrets and variables → Actions**:

### Vercel deployment

- `VERCEL_TOKEN`
- `VERCEL_ORG_ID`
- `VERCEL_PROJECT_ID`

The Vercel project must use `auth-api` as its root directory. Configure its Production environment with the same values documented in `auth-api/.env.example`:

- `FIREBASE_PROJECT_ID`
- `FIREBASE_WEB_API_KEY`
- `FIREBASE_SERVICE_ACCOUNT_JSON`
- `OTP_HMAC_SECRET`
- `RESEND_API_KEY`
- `RESEND_FROM_EMAIL`

Do not set `LOCAL_ADMIN_OTP_BYPASS=1` in production. The bypass is disabled automatically on Vercel.

### Flutter web packaging

These are Firebase **web client** values, not the Admin service account:

- `FLUTTER_FIREBASE_API_KEY`
- `FLUTTER_FIREBASE_PROJECT_ID`
- `FLUTTER_FIREBASE_MESSAGING_SENDER_ID`
- `FLUTTER_FIREBASE_WEB_APP_ID`
- `FLUTTER_FIREBASE_AUTH_DOMAIN`
- `FLUTTER_FIREBASE_STORAGE_BUCKET`

The `netra-web-release` artifact is available from the successful GitHub Actions run. It uses `https://auth.neuroshift.dev` for authentication.

**Do not add `OCR_API_KEY` to a public Flutter build.** Dart defines are visible to anyone who downloads the app. Public OCR access needs a server-side proxy or server-side Firebase ID-token verification at the OCR boundary. The release artifact deliberately omits that private key.

## Point auth.neuroshift.dev to Vercel

1. In the Vercel project, open **Settings → Domains** and add `auth.neuroshift.dev`.
2. In Cloudflare DNS, create the exact record Vercel displays for the `auth` hostname. Use the target shown in your Vercel dashboard rather than guessing it.
3. Keep the separate `mails.neuroshift.dev` Resend SPF/DKIM records unchanged.
4. Wait for DNS and Vercel verification, then deploy through GitHub Actions.

A successful deployment checks the domain with an intentionally invalid token. `400` or `401` proves the API route is reachable; it is not a login failure.

You can also check manually:

```bash
curl -X POST https://auth.neuroshift.dev/api/auth/session/status \
  -H "Content-Type: application/json" \
  -d '{"idToken":"manual-health-check"}'
```

## Flutter hosting boundary

The workflow packages Flutter web but does not deploy it to a public host. A hosting provider and app domain were not specified, and secure public OCR still needs the server-side boundary described above. Once those are chosen, the release artifact can be deployed without rebuilding the auth API or Modal model.
