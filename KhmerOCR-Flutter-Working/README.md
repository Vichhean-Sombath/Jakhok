# Khmer OCR Flutter UI

The existing scanner UI connects to `../Khmer-OCR-App` for image OCR on Android, iOS, and web. Its screens, local document storage, text-document extraction, and mock chat are preserved. Images are sent to the service; OCR is no longer performed by ML Kit or Tesseract.

## Start the service

From `Khmer-OCR-App`, run `run.bat` on Windows or `bash run_mac.command` on macOS. The existing launchers and service code are unchanged. Windows needs a real Python installation available as `python`; the Windows Store alias alone is insufficient. Initial setup installs the service dependencies and may download model files.

Open http://localhost:7860/api/status and wait until `status` is `ready`. Model loading can take time. A running HTTP server does not necessarily mean the model is ready. Keep the service terminal running. Its existing web studio remains at http://localhost:7860.

## Run Flutter

From this folder, run `flutter pub get`, then choose the address reachable from the target device:

```sh
# Browser on the service computer (Edge; use chrome if installed)
flutter run -d edge --dart-define=OCR_API_BASE_URL=http://localhost:7860

# Standard Android emulator on the service computer
flutter run -d <android-device-id> --dart-define=OCR_API_BASE_URL=http://10.0.2.2:7860

# Physical Android or iOS device: replace the example with your computer's LAN IP
flutter run -d <device-id> --dart-define=OCR_API_BASE_URL=http://192.168.1.100:7860
```

Use `flutter devices` to find device IDs and `ipconfig` on Windows to find the active LAN IPv4 address. Phones must be on the same network as the service computer. Allow the Python service through Windows Firewall on your private network for TCP port 7860. A phone's `localhost` refers to the phone, not your computer. Verify `/api/status` from the phone's browser if the connection fails.

Android requires the Android SDK. Local HTTP is enabled in debug/profile builds; release builds should use an HTTPS service URL. iOS builds require macOS/Xcode; allow local-network access when prompted. iOS local networking is enabled through its transport security configuration. On newer iOS versions, if a raw LAN IP is blocked by transport security, use the computer's resolvable `.local` hostname or HTTPS.

The default URL is `http://localhost:7860`. Set `OCR_API_BASE_URL` for emulators/devices and rebuild when changing it. The status check times out after 10 seconds. OCR defaults to 600 seconds per image/page and can be changed at launch/build time:

```sh
flutter run -d edge --dart-define=OCR_API_BASE_URL=http://localhost:7860 --dart-define=OCR_TIMEOUT_SECONDS=900
```

An HTTPS-hosted Flutter site must use an HTTPS API to avoid browser mixed-content blocking. The service already provides CORS support; no service changes are required. Browser camera access requires localhost or a secure origin. Browser PDF rendering loads the PDF.js assets configured in `web/index.html` from a CDN, so it needs internet access on first load.

## Processing behavior

- Camera, gallery, and image-file imports upload image bytes as multipart `file` to `/api/ocr` after checking `/api/status`.
- The service owns inference defaults: OCR task, Khmer LoRA, smart hybrid detection, and token limits.
- PDFs keep existing text layers; pages without text are rendered and uploaded sequentially. A failed page aborts the operation without saving an incomplete document.
- Other supported text/Office/archive imports retain their existing local extraction behavior. ZIP extraction behavior is unchanged.
- Errors and model-loading messages appear in the existing scan screen. The selected file remains available for retry. There is no automatic upload retry or fallback OCR engine.
- The service accepts image formats supported by its installed Pillow decoders. Unsupported images produce a service error; convert them to PNG/JPEG if necessary.
- Saved documents, themes, navigation, and local mock chat retain their existing behavior. No AI chat endpoint has been added.

## Checks

```sh
flutter analyze --no-fatal-infos
flutter test
flutter build web --dart-define=OCR_API_BASE_URL=http://localhost:7860
flutter build apk --debug --dart-define=OCR_API_BASE_URL=http://10.0.2.2:7860
```

For a live smoke test, wait for model readiness, import a clear Khmer PNG/JPEG, select Extract Text, and verify the Khmer result appears in the existing result/chat flow and remains after restarting the app. Repeat with a PDF containing both text and scanned pages. Stop the service and retry to verify the existing error panel reports the connection failure without saving an empty document.
