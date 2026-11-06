# Flutter UI Prompt: OCR Document Scanner with DeepSeek-Style Interface

## Role

You are a Senior Flutter Engineer and UI/UX Specialist. Build a Flutter app that is functionally an **OCR/Document Scanner with AI Chat**, but visually styled to match the **DeepSeek mobile app's design language exactly**.

## Critical Constraint

This is **NOT** a DeepSeek functional clone. The app must have **Document Scan/Upload as the primary entry point**, with **AI Chat as a secondary feature**. However, every screen must follow DeepSeek's visual design system: flat, neutral, spacious, and calm.

---

## Design System (DeepSeek Visual Language)

| Token | Value |
|---|---|
| Background (Light) | `#FFFFFF` |
| Background (Dark) | `#1A1A1A` |
| Primary Text | `#1F1F1F` |
| Secondary / Placeholder | `#8E8E8E` |
| Borders / Dividers | `#E5E5E5` |
| Accent (active toggles) | `#6C8CE4` (subtle purple/blue tint) |
| Body Font | Inter or SF Pro, 16sp |
| Monospace Font | Courier or Roboto Mono (for OCR text & code) |
| Edge Padding | 16dp |
| Shadows | None. Zero elevation. Flat design only. |

---

## Screen 1: Home / Document Hub

The first screen users see.

- **AppBar:** Minimalist. Left: Menu/History icon (hamburger). Center: "Documents" or app name. Right: "+ New Scan" icon. **No elevation.**
- **Body:** Vertical list of recently scanned documents. Each item is a flat row containing:
  - Small document icon (PDF/Image) on the left.
  - Filename (truncated) and scan date.
  - Subtle chevron or "Chat" button on the right to open AI chat about that specific document.
- **Floating Action Button:** Large, flat circular button at bottom center/right labeled **"Scan Document"** with a camera icon. This is the primary action. Style it like DeepSeek's send button — solid black in light mode, white in dark mode.

---

## Screen 2: Scan / Capture View (OCR Flow)

- **Camera preview** fills the screen (use `camera` or `docovue` package).
- **Overlay:** Simple white bounding box frame with corner brackets (no heavy UI). Text below: "Position document in frame."
- **Bottom Controls:** Minimal row:
  - Flash toggle (left)
  - Large capture button (center, circular)
  - Gallery import icon (right)
  - All icons thin-line style, white on semi-transparent dark bar.
- **After Capture:** Preview screen with scanned image. Two flat buttons at bottom:
  - **"Extract Text"** (primary, filled)
  - **"Retake"** (text-only)
  - No shadows.

---

## Screen 3: Document Detail / OCR Result

- **AppBar:** Back arrow, document name (truncated), overflow menu (Share/Delete).
- **Body:** Scrollable view showing:
  1. Thumbnail of scanned image (small, tappable to enlarge).
  2. Extracted text in monospace font on slightly tinted background (`#F7F7F7`) with "Copy" icon in corner.
  3. Prominent **"Chat with this Document"** button (filled, DeepSeek-style: black bg, white text, rounded corners). This bridges to AI chat.

---

## Screen 4: AI Chat (Styled Exactly Like DeepSeek)

- **AppBar:** Minimal. Back arrow. Center: "Chat" + document name context. Right: New Chat (+) icon.
- **Message List:**
  - **User Message:** Right-aligned. Light grey bubble (`#F2F2F2`), black text, 18dp radius. Padding 12×16.
  - **Assistant Message:** Left-aligned. No bubble. Small icon (12dp) at top left. Markdown rendered fully. Streaming cursor at end if typing.
  - **Code / Extracted Text Blocks:** Distinct background, language label header, copy button.
- **Composer (Critical for DeepSeek Look):**
  - Rounded rectangle card floating above keyboard. White background with `#E5E5E5` border.
  - **Inside the card, top row:** Two toggleable chips side by side:
    - **"DeepThink"** (Brain icon) — for complex OCR queries.
    - **"Search"** (Globe icon) — for web-augmented answers.
    - When active: chip background becomes light purple tint, border becomes purple.
  - **Input Field:** Expands vertically (max 6 lines). Placeholder: "Ask about this document…". No border on field.
  - **Bottom Row:**
    - Left: Paperclip icon (attach another doc/image).
    - Right: Send button (circle, arrow up). Disabled (grey) until text entered; active (black) when typing.

---

## Interaction Details

- Keyboard resizing: `resizeToAvoidBottomInset: true`. Composer sticks to bottom.
- Streaming: Assistant text appears token-by-token. ListView auto-scrolls smoothly.
- **Scan → Chat flow:** After OCR extraction, tapping "Chat with this Document" navigates to Screen 4 with extracted text pre-loaded as context in the first system message.

---

## Technical Constraints (Flutter Specific)

- **Packages to use:**
  - `camera` or `docovue` for scanning.
  - `flutter_smooth_markdown` or `streamdown` for streaming markdown in chat.
  - `flutter_hooks` or standard `StatefulWidget` for state.
- **Modularity:** Separate widgets for `MessageBubble`, `Composer`, `DocumentListItem`, `ScanOverlay`.
- **Deliverable:** Complete runnable code (or clearly separated screen files) with mock data so the UI can be previewed immediately. **No backend API calls** — focus on visual states and navigation.

---

## Output Format

Provide the Flutter code, followed by a brief note on:

1. How to swap the accent color.
2. How to adjust the scan overlay frame style.