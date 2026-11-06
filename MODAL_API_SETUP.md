# OpenKhmer OCR API on Modal

The API-only Modal deployment is live at:

```text
https://dvdlosser--openkhmer-ocr-serve.us-east.modal.run
```

Deployment dashboard: <https://modal.com/apps/dvdlosser/main/deployed/openkhmer-ocr>

It exposes the existing FastAPI routes only:

- `GET /api/status`
- `POST /api/detect`
- `POST /api/ocr`
- `POST /api/ocr/stream`

Every route requires the `x-api-key` header. The server reads `OPENKHMER_API_KEY` from the Modal secret named `openkhmer-api-key`. The private Hugging Face read token comes from `openkhmer-hf-read`.

Browser CORS is restricted to the Flutter web app origins in `OCR_ALLOWED_ORIGINS`: local Chrome (`http://localhost:8080`, `http://127.0.0.1:8080`) and the Neuroshift root/www domains. If the Flutter web app is hosted elsewhere, add its exact origin to that comma-separated list in `modal_app.py`, then redeploy. This is separate from the Vercel auth API's `AUTH_ALLOWED_ORIGINS` setting.

## Flutter connection

`OcrApiClient` now defaults to the Modal URL and reads `OCR_API_KEY` at compile time. For local Chrome development, from the Flutter project directory run:

```powershell
$keyLine = Get-Content "C:\Users\dvdphobia\Documents\OCR-App\.env.modal-client" |
  Where-Object { $_.StartsWith('OCR_API_KEY=') } |
  Select-Object -First 1
$apiKey = ($keyLine -split '=', 2)[1]
flutter run -d chrome `
  --dart-define=OCR_API_BASE_URL=https://dvdlosser--openkhmer-ocr-serve.us-east.modal.run `
  "--dart-define=OCR_API_KEY=$apiKey"
```

To use the local backend instead, set `OCR_API_BASE_URL=http://localhost:7860` and configure that local API's key if API-only mode is enabled.

The generated key is stored in the ignored local file `.env.modal-client`; do not commit or share it. A key passed to a Flutter web or mobile build is embedded in the client and can be extracted. Use this direct-key setup only for private development. Before publishing the app, switch to per-user Firebase token verification in the API or a trusted backend proxy that keeps the Modal key server-side.

To apply OCR CORS changes to the live Modal app, run `modal deploy modal_app.py` from this directory after logging into Modal.

## Cold starts and cost

The Modal function requests an L40S GPU, allows one container, and scales it down after 2 seconds without a request. It does not reserve a GPU continuously. The first request after scale-to-zero starts the container and loads the models; the Flutter client polls `/api/status` while the model reports `loading`. The Modal model cache is kept in a persistent Volume.

Modal currently lists the L40S at `$0.000542` per GPU-second (about `$1.95` per GPU-hour), plus CPU and memory charges. Container loading and the configured scale-down window are billable; once the container reaches zero, idle GPU compute stops. See [Modal pricing](https://modal.com/pricing).
