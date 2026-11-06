---
title: Khmer PaddleOCR VL
emoji: 🇰🇭
colorFrom: indigo
colorTo: purple
sdk: docker
app_port: 7860
pinned: false
license: apache-2.0
---

# 🇰🇭 Khmer PaddleOCR-VL Web App

A fast, modern web application for **Khmer Document & Text OCR** powered by your fine-tuned Vision-Language LoRA model [`dvdphobia/Khmer-PaddleOCR-VL-LoRA`](https://huggingface.co/dvdphobia/Khmer-PaddleOCR-VL-LoRA) built on top of [`unsloth/PaddleOCR-VL`](https://huggingface.co/unsloth/PaddleOCR-VL).

## ✨ Features

- **FastAPI Backend + Modern Khmer Web Studio**:
  - **Drag & Drop Image Upload** (`PNG`, `JPG`, `WEBP`, `BMP`)
  - **Direct Clipboard Paste (`Ctrl+V`)** anywhere on the page
  - **Built-in Khmer Sample Generator** for 1-click testing
  - **Image Rotation (`90°`)** directly in the browser
  - **Real-time Token Streaming** via Server-Sent Events (SSE)
  - **LoRA vs. Base Model Comparison**: Toggle or compare [`dvdphobia/Khmer-PaddleOCR-VL-LoRA`](https://huggingface.co/dvdphobia/Khmer-PaddleOCR-VL-LoRA) against the base [`unsloth/PaddleOCR-VL`](https://huggingface.co/unsloth/PaddleOCR-VL) side-by-side
  - **One-Click Copy & Export** to `.TXT`, `.MD`, and `.JSON`

---

## 🚀 Quick Start (Windows NVIDIA GPU & Mac Apple Silicon M1–M4 Pro)

### 🍎 macOS (Mac M1 / M2 / M3 / M4 Pro — Apple Metal `MPS` GPU)
1. Unzip `Khmer-OCR-App-Share.zip` and open Terminal in the `Khmer-OCR-App` folder (or double-click `run_mac.command` in Finder):
   ```bash
   bash run_mac.command
   ```
   *(On first run, use the updater command below to create `.venv`, install dependencies, sync the configured checkpoint, and start the app.)*
2. To pull and activate the configured checkpoint before starting the app:
   ```bash
   bash update_latest_checkpoint_mac.command
   ```
   To sync without starting FastAPI or loading the OCR model, run `./.venv/bin/python sync_checkpoint.py`.
3. Open **[http://localhost:7860](http://localhost:7860)** in your browser.

### 🪟 Windows (NVIDIA RTX GPU — `CUDA`)
1. Double-click **`run.bat`** (or run in PowerShell):
   ```powershell
   .\run.bat
   ```
   *(For first-time setup, double-click the updater below; it creates `.venv`, installs CUDA PyTorch + dependencies, syncs the configured checkpoint, and starts the server.)*
2. To pull and activate the configured checkpoint, double-click **`update_latest_checkpoint.bat`**.
   To sync without starting FastAPI or loading the OCR model, run `\.venv\Scripts\python.exe sync_checkpoint.py`.
3. Open **[http://localhost:7860](http://localhost:7860)** in your browser.

### 🔐 Local Hugging Face credentials

The app reads optional credentials from `.env` in the project folder. The checked-in `.env.example` is a blank template; copy it to `.env` if needed. Keep `.env` private and do not add it to a commit, notebook, or share archive.

- Public downloads of `dvdphobia/Khmer-PaddleOCR-VL-LoRA` need no token; set `LORA_MODEL_ID=dvdphobia/Khmer-PaddleOCR-VL-LoRA` to select it explicitly.
- The default `PRIVATE_RUN_ID` is `2aa94c1b9590b1f3`, the A100 phase. Its optimizer step (currently 2,600 from the Modal Volume) is distinct from its warm-start parent step (157,938). The app uses the EMA export from that phase's `adapter/` folder and keeps the parent lineage in checkpoint metadata; it does not combine weights across runs or phases.
- The updater scripts set `AUTO_PULL_LATEST_CHECKPOINT=1`, fetch the configured run at one pinned Hugging Face revision, and activate it through `checkpoints/active_checkpoint.json`. Normal app startup uses that validated local marker offline. If no marker exists or it points to a different/invalid run, startup asks you to sync instead of selecting another checkpoint.
- To sync without starting the app, run `python sync_checkpoint.py` from the project folder after dependencies are installed. Downloads are stored under `checkpoints/runs/<run-id>/phase-step-<step>-<content-id>/`; earlier checkpoint folders are preserved. Set `PRIVATE_RUN_ID` to select another run. An explicit `LORA_MODEL_ID` overrides checkpoint selection and skips all private checkpoint sync; use `LORA_MODEL_ID=dvdphobia/Khmer-PaddleOCR-VL-LoRA` to select that public adapter.
- To import a checkpoint copied from the Modal Volume without claiming an HF revision, pass a local directory containing `state.json` and `adapter/`: `python sync_checkpoint.py --local-checkpoint <checkpoint-dir> --source-identity "Modal Volume checkpoint-000002600"`. The importer validates the same run/parent metadata and EMA adapter, records Modal provenance separately, and refuses to replace a newer active step with an older HF copy.
- Only set `HF_PRIVATE_CHECKPOINT_TOKEN` on a trusted machine that needs private checkpoint sync. Use a fine-grained read token restricted to `dvdphobia/OpenKhmer-Private-Checkpoints`.
- `HF_WRITE_TOKEN` is only for `merge_checkpoint.py` when publishing. Use a separate fine-grained write token restricted to the destination model repo.

If a token was exposed, revoke it in Hugging Face **Settings → Access Tokens** and create a replacement with the narrowest required access. A `.env` file protects the value from being checked in; token permissions still determine what its holder can access. See [Hugging Face token security guidance](https://huggingface.co/docs/hub/security-tokens).

---

## ☁️ Deploy to Hugging Face Spaces

This project is pre-configured with a `Dockerfile` and Hugging Face Spaces YAML frontmatter in `README.md`:

1. Create a new Space on [Hugging Face Spaces](https://huggingface.co/new-space) and select **Docker** as the Space SDK.
2. Push this repository to your Space:
   ```bash
   git init
   git remote add space https://huggingface.co/spaces/dvdphobia/Khmer-PaddleOCR-VL
   git add .
   git commit -m "Initial deploy of Khmer PaddleOCR-VL app"
   git push --force space main
   ```

---

## 🔌 API Endpoints

- `GET /api/status` — Returns model loading status, active device (`CUDA` / `CPU`), and dtype (`bfloat16` / `float16` / `float32`).
- `POST /api/ocr` — Multipart form upload (`file`, `task`, `max_new_tokens`, `use_lora`) returning JSON OCR text and timing metrics.
- `POST /api/ocr/stream` — Server-Sent Events (SSE) endpoint streaming tokens live as they are generated.
