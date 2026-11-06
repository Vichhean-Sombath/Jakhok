# Firebase Google sign-in setup

The app gates the scanner behind Firebase Authentication and requires an emailed OTP after Google or email/password sign-in. The public Firebase client settings for `netra-ocr` and the auth API URL are configured as defaults in the app. You can override them at build time for a different Firebase project. Never put Firebase Admin service-account credentials or private keys in the Flutter app.

## Web / Chrome

1. Create or select a Firebase project and register a Web app.
2. In Firebase Console, enable **Authentication → Sign-in method → Google** and **Email/Password**. Email/password registration and login send an OTP through the auth API before Firebase signs the user in.
3. Add the domain used by the app under **Authentication → Settings → Authorized domains**. For local development, add `localhost` and/or `127.0.0.1`; add the deployed Vercel domain before release.
4. The current Web app config is already included, so a standard Chrome run can be started with:

```powershell
flutter run -d chrome
```

For a local login session with the local OTP bypass, run `run_web_local.ps1` from this folder in PowerShell. It starts `auth-api` on `127.0.0.1:3000`, then launches Flutter Chrome with `AUTH_API_BASE_URL=http://127.0.0.1:3000`. The script reads the Firebase web client settings from this folder's `.env.local` and does not rewrite that file. It sets `LOCAL_ADMIN_OTP_BYPASS=1` only in the environment of the auth API process it starts; it does not change the current PowerShell environment or any checked-in configuration. When Flutter exits, the script stops only the auth API process tree it started. If port 3000 is already occupied, the script exits with an error and leaves the existing process alone.

The launcher requires Node.js 20 or newer, npm, Flutter, installed `auth-api` dependencies, and a private `auth-api/.env.local` with the local server settings. Keep backend credentials in that file and out of the Flutter app. Do not use the local bypass setting for a deployed auth API.

For the Modal OCR service, the launcher also reads `OCR_API_KEY` from the parent folder's `.env.modal-client` and runs Chrome at `http://localhost:8080`, an origin allowed by the service. The key is included in the development web build, so this setup is for private local use, not a public deployment.

For a different Firebase project, pass its client settings with `--dart-define=FIREBASE_API_KEY=...`, `FIREBASE_WEB_APP_ID`, `FIREBASE_MESSAGING_SENDER_ID`, `FIREBASE_PROJECT_ID`, and optionally `FIREBASE_AUTH_DOMAIN` and `FIREBASE_STORAGE_BUCKET`. These Firebase client settings are visible in the built app; keep Admin credentials and private server keys on the auth backend.

Deploy the separate OTP service in `C:\Users\dvdphobia\Documents\OCR-App\auth-api`. Its Vercel and Resend setup, Firebase Admin credentials, and Cloudflare DNS steps are in that folder's `README.md`. Set `AUTH_API_BASE_URL` to the deployed auth API origin when building Flutter. Add the Flutter web hostname to Firebase's authorized domains.

## Android and iOS

The Android app is registered in Firebase as `dev.neuroshift.netra`. The Flutter Android `namespace` and `applicationId` are set to match. The Firebase Android App ID is `1:704320136855:android:468f36fd977381b69eabd2`; use the API key from that Android app's config for Android builds. For Google sign-in, add the Android debug SHA-1 fingerprint in Firebase Authentication settings, and add the release fingerprint before publishing. The OAuth client ID with `client_type: 3` is the server client ID for native Google sign-in.

Example Android run (replace `YOUR_ANDROID_API_KEY` with the Android app's `current_key` from its Firebase config):

```powershell
flutter run -d <android-device-id> `
  --dart-define=FIREBASE_API_KEY=YOUR_ANDROID_API_KEY `
  --dart-define=FIREBASE_PROJECT_ID=netra-ocr `
  --dart-define=FIREBASE_MESSAGING_SENDER_ID=704320136855 `
  --dart-define=FIREBASE_ANDROID_APP_ID=1:704320136855:android:468f36fd977381b69eabd2 `
  --dart-define=GOOGLE_SERVER_CLIENT_ID=704320136855-ftagrvio59sc2bce1rcqvs7rjbgl0vvb.apps.googleusercontent.com `
  --dart-define=AUTH_API_BASE_URL=https://auth.neuroshift.dev
```

For Chrome, register a separate Web app and use its Web app ID and API key. Supply `AUTH_API_BASE_URL` on native builds too; the OTP check is required for both Google and email/password sessions. Also provide the common Firebase values and the platform app ID described below.

## Compile-time variables

| Variable | Required for |
| --- | --- |
| `FIREBASE_API_KEY` | Optional override; default is the `netra-ocr` client key |
| `FIREBASE_PROJECT_ID` | Optional override; default is `netra-ocr` |
| `FIREBASE_MESSAGING_SENDER_ID` | Optional override; default is `704320136855` |
| `FIREBASE_WEB_APP_ID` | Optional override; default is the registered `netra-ocr` Web app |
| `FIREBASE_ANDROID_APP_ID` | Optional override; default is the registered `netra-ocr` Android app |
| `FIREBASE_IOS_APP_ID` | iOS/macOS |
| `FIREBASE_IOS_BUNDLE_ID` | iOS/macOS (recommended) |
| `FIREBASE_AUTH_DOMAIN` | Web (optional) |
| `FIREBASE_STORAGE_BUCKET` | Optional |
| `AUTH_API_BASE_URL` | All platforms; deployed OTP API origin |
| `GOOGLE_SERVER_CLIENT_ID` | Native OAuth setup when required |
