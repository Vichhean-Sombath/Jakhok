# Document Scanner

DeepSeek-inspired Flutter document hub, scanner, OCR result, and local mock chat.

## Run

Android and iOS project scaffolding is included. With Flutter 3.38 or newer installed, fetch packages and launch on a connected device or emulator:

```sh
flutter pub get
flutter run
```

The app uses Camera, Image Picker, File Picker, Google ML Kit Text Recognition, Syncfusion PDF text extraction, Shared Preferences, Path Provider, and Permission Handler. Camera/gallery images are copied into the app's documents directory; document metadata and the selected theme are saved locally.

Use the attachment button on the scan screen to import a file. Image files and image-only PDF pages use on-device OCR. Text extraction supports PDF text layers, DOCX/XLSX/PPTX, OpenDocument, EPUB, ZIP files containing supported documents, subtitle formats, email, and common plain-text/data/code formats. Legacy binary Office files such as DOC/XLS/PPT and media files such as audio/video are not text documents and need conversion or a separate transcription engine.

The camera and photo library usage descriptions, Android camera permission, and iOS 15.5 deployment target are configured in the platform files.

## Preview behavior

- Scanning, gallery selection, OCR, local document saving, document detail, and chat navigation work without a backend.
- The chat streams a local mock answer. Replace `_mockAnswer` in `lib/screens/chat_screen.dart` with the future API integration.
- OCR is configured for Latin script via Google ML Kit. Khmer OCR requires a Khmer-capable on-device recognition model; the project does not include trained Khmer model data yet.

## Styling

- Change `AppTheme.accent` in `lib/theme.dart` to update active mode chips and accents.
- Adjust the `length`, `stroke`, or frame dimensions in `lib/widgets/scan_overlay.dart` to restyle the scan guides.
