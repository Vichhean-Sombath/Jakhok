# Flutter App Spec: OCR Document Scanner with DeepSeek-Style UI

## Role
You are a Senior Flutter Engineer and UI/UX Specialist. Build a Flutter app that is functionally an OCR/Document Scanner with AI Chat, but visually styled to match the DeepSeek mobile app's design language exactly.

## Critical Constraint
This is NOT a DeepSeek functional clone. The app must have Document Scan/Upload as the primary entry point, with AI Chat as a secondary feature. Every screen must follow DeepSeek's visual design system: flat, neutral, spacious, and calm.

Deliverable: Complete, runnable Flutter code with mock data so the UI can be previewed immediately. No backend API calls — focus on visual states, navigation, and state management. Separate widgets into modular files.

---

# PART 1: DESIGN SYSTEM

- Background (Light): #FFFFFF
- Background (Dark): #1A1A1A
- Primary Text: #1F1F1F
- Secondary / Placeholder: #8E8E8E
- Borders / Dividers: #E5E5E5
- Accent (active toggles): #6C8CE4 (subtle purple/blue tint)
- Body Font: Inter or SF Pro, 16sp
- Monospace Font: Courier or Roboto Mono (OCR text & code)
- Edge Padding: 16dp
- Shadows: None. Zero elevation. Flat design only.

---

# PART 2: SCREENS (UI)

## Screen 1: Home / Document Hub
- AppBar: Minimalist. Left: Menu/History icon (hamburger). Center: "Documents" or app name. Right: "+ New Scan" icon. No elevation.
- Body: Vertical list of recently scanned documents. Each item is a flat row with:
  - Small document icon (PDF/Image) on the left.
  - Filename (truncated) and scan date.
  - Subtle chevron or "Chat" button on the right.
- Floating Action Button: Large, flat circular button labeled "Scan Document" with camera icon. Solid black (light mode) / white (dark mode).
- Empty State: Illustration + "Scan Your First Document" CTA.

## Screen 2: Scan / Capture View
- Camera preview fills the screen (use camera or docovue).
- Overlay: Simple white bounding box with corner brackets. Text below: "Position document in frame."
- Bottom Controls: Flash toggle (left), large circular capture button (center), gallery import icon (right). Thin-line icons, white on semi-transparent dark bar.
- After Capture: Preview screen with scanned image. Two flat buttons:
  - "Extract Text" (primary, filled)
  - "Retake" (text-only)

## Screen 3: Document Detail / OCR Result
- AppBar: Back arrow, document name (truncated), overflow menu (Share/Delete/Rename).
- Body: Scrollable view showing:
  1. Thumbnail of scanned image (tappable to enlarge).
  2. Extracted text in monospace font on tinted background (#F7F7F7) with "Copy" icon.
  3. Prominent "Chat with this Document" button (filled, black bg, white text, rounded corners).

## Screen 4: AI Chat (DeepSeek-Style)
- AppBar: Minimal. Back arrow. Center: "Chat" + document name. Right: New Chat (+) icon.
- Message List:
  - User Message: Right-aligned. Light grey bubble (#F2F2F2), black text, 18dp radius. Padding 12x16.
  - Assistant Message: Left-aligned. No bubble. Small icon (12dp) top-left. Full Markdown rendering. Streaming cursor at end if typing.
  - Code / Extracted Text Blocks: Distinct background, language label header, copy button.
- Composer (Critical for DeepSeek Look):
  - Rounded rectangle card floating above keyboard. White background, #E5E5E5 border.
  - Top row inside card: Two toggleable chips:
    - "DeepThink" (Brain icon) — complex OCR queries.
    - "Search" (Globe icon) — web-augmented answers.
    - Active state: light purple tint background, purple border.
  - Input Field: Expands vertically (max 6 lines). Placeholder: "Ask about this document...". No border.
  - Bottom Row:
    - Left: Paperclip icon (attach another document).
    - Right: Send button (circle, arrow up). Disabled (grey) until text entered; active (black) when typing.
- Empty Chat State: Suggested prompts: "Summarize this document", "What are the key points?", "Translate to Spanish".

---

# PART 3: BUSINESS FLOW & NAVIGATION

High-Level Flow:
Home / Doc Hub -> Document Detail -> AI Chat
Home / Doc Hub -> Scan / Capture -> Preview & Extract -> Document Detail

## Screen-by-Screen Logic

App Launch to Home
1. Check local storage for previously scanned documents.
2. First launch: show empty state with CTA.
3. Otherwise: load document list sorted by most recent.
4. Offline-first — no network call required.

Home to Scan
1. Request camera permission.
2. If denied: show explanation dialog with "Open Settings" button.
3. If granted: launch camera preview with overlay.
4. Fallback: If camera unavailable (emulator), show "Camera not available" with gallery import option.

Scan to Preview & Extract
1. User captures image (or picks from gallery).
2. Preview screen appears.
3. User taps "Extract Text" -> run OCR engine on-device (docovue / ML Kit).
4. Show progress indicator.
5. Success: Save to local DB -> navigate to Document Detail.
6. Failure: Show "Couldn't read text" with "Retry" / "Retake" options.

Preview to Document Detail
1. Save document metadata to local DB:
   - ID (UUID), filename (Scan_YYYYMMDD_HHMMSS), scan date
   - Image path, extracted text, OCR confidence score
2. Navigate to Document Detail screen.

Document Detail to AI Chat
1. User taps "Chat with this Document".
2. Initialize chat with system prompt including OCR text: "The user has scanned a document. Extracted text: [OCR_TEXT]. Answer questions about it."
3. Navigate to Chat screen.
4. Hide the "Chat" button if OCR text is empty.

Chat Interaction
1. User types message, taps send.
2. User message appears right-aligned; input clears; send button disables.
3. Request sent to AI (system prompt + history + user message + active toggles).
4. Response streams token-by-token; assistant message appears left-aligned.
5. Auto-scroll as text arrives.
6. On complete: cursor disappears, composer re-enables.

Chat to Attach Document
1. User taps paperclip.
2. Bottom sheet: "Scan New Document" / "Choose from Gallery" / "Select Existing Document".
3. New document's OCR text appended to chat context.
4. System message: "Added document: [filename]".

---

# PART 4: STATE MANAGEMENT

AppState:
- ThemeMode (light/dark)
- UserPreferences (accent color, font size)
- DocumentList (cached metadata)

DocumentState:
- Document (metadata + OCR text)
- OCRStatus (idle / processing / success / failed)
- ChatHistory (list of messages)

ChatState:
- Messages (list)
- StreamingStatus (idle / streaming / complete / error)
- DeepThinkEnabled (bool)
- SearchEnabled (bool)
- AttachedDocuments (list of document IDs)

---

# PART 5: DATA STORAGE

- Document images: Local file system (Large binary; offline)
- OCR text: Local DB (SQLite / Hive) (Fast retrieval, searchable)
- Chat history: Local DB (Offline access, privacy)
- User preferences: SharedPreferences (Lightweight key-value)
- API keys: flutter_secure_storage (Security)

---

# PART 6: ERROR HANDLING

- Camera permission denied: "Camera access is required to scan documents." -> "Open Settings"
- OCR failed: "Couldn't read text from this image." -> "Retry" / "Retake"
- No text detected: "No text found in image." -> "Retake"
- Storage full: "Storage full. Delete old documents." -> Navigate to Document Hub
- Network offline: "You're offline. Chat requires internet." -> Retry when online
- API rate limit: "Too many requests. Wait a moment." -> Auto-retry after 60s
- API error (500): "Something went wrong. Try again." -> "Retry"
- Token limit exceeded: "Document too large for chat context." -> Suggest Search mode

---

# PART 7: TECHNICAL CONSTRAINTS

Packages:
- camera or docovue (document scanning)
- flutter_smooth_markdown or streamdown (streaming markdown in chat)
- flutter_hooks or standard StatefulWidget (state)
- flutter_secure_storage (API keys)
- hive or sqflite (local DB)
- shared_preferences (user preferences)

Modularity:
Separate widgets into their own files:
- MessageBubble (user/assistant message rendering)
- Composer (input card with chips + send button)
- DocumentListItem (flat row in document hub)
- ScanOverlay (camera bounding box + corner brackets)
- DeepThinkChip / SearchChip (toggleable mode chips)

Interaction Details:
- resizeToAvoidBottomInset: true (composer sticks to bottom with keyboard)
- Auto-scroll ListView smoothly as streaming tokens arrive.
- ListView.builder for performance with long message lists.
- Handle dark mode via ThemeData.dark() with the same design tokens.

---

# PART 8: OUTPUT FORMAT

Provide:
1. Complete runnable Flutter code — either one main.dart or clearly separated screen files with mock data for immediate preview.
2. Brief note on:
   - How to swap the accent color.
   - How to adjust the scan overlay frame style.
   - How to swap the mock AI response with a real API call (for future integration).

---

# PART 9: SUCCESS CRITERIA

- User can scan a document and extract text in under 5 seconds.
- User can open AI chat about a document in one tap.
- Chat streaming feels responsive (< 1s to first token).
- Zero crashes on core flows (scan, OCR, chat).
- App works offline for scan + OCR; chat requires network.
- UI matches DeepSeek design language pixel-for-pixel — flat, neutral, spacious, calm.