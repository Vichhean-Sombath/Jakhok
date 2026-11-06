"""Serve the OpenKhmer OCR FastAPI app on Modal."""

from pathlib import Path

import modal


ROOT = Path(__file__).resolve().parent
APP_DIR = "/app"
CHECKPOINTS_DIR = f"{APP_DIR}/checkpoints"

app = modal.App("openkhmer-ocr")

# Keep the Hugging Face model cache and the private LoRA checkpoint between
# Modal container starts. The app's existing checkpoint sync code writes here.
model_volume = modal.Volume.from_name(
    "openkhmer-ocr-model-cache",
    create_if_missing=True,
    version=2,
)

image = (
    modal.Image.debian_slim(python_version="3.12")
    .workdir(APP_DIR)
    .apt_install("libgl1", "libglib2.0-0", "libgomp1")
    .pip_install_from_requirements(str(ROOT / "requirements.txt"))
    .env(
        {
            "AUTO_PULL_LATEST_CHECKPOINT": "1",
            "PRIVATE_RUN_ID": "2aa94c1b9590b1f3",
            "PRIVATE_CHECKPOINT_REPO": "dvdphobia/OpenKhmer-Private-Checkpoints",
            "API_ONLY": "1",
            "OCR_ALLOWED_ORIGINS": "http://localhost:8080,http://127.0.0.1:8080,https://neuroshift.dev,https://www.neuroshift.dev",
            "HF_HOME": f"{CHECKPOINTS_DIR}/.hf-cache",
            "HF_HUB_DISABLE_XET": "1",
            "HF_HUB_DISABLE_IMPLICIT_TOKEN": "1",
            "PYTHONUNBUFFERED": "1",
        }
    )
    .add_local_file(str(ROOT / "app.py"), remote_path=f"{APP_DIR}/app.py")
    .add_local_file(
        str(ROOT / "checkpoint_sync.py"),
        remote_path=f"{APP_DIR}/checkpoint_sync.py",
    )
)


@app.function(
    image=image,
    gpu="L40S",
    timeout=900,
    startup_timeout=900,
    max_containers=1,
    scaledown_window=2,
    volumes={CHECKPOINTS_DIR: model_volume},
    secrets=[
        modal.Secret.from_name("openkhmer-hf-read"),
        modal.Secret.from_name("openkhmer-api-key"),
    ],
)
@modal.asgi_app()
def serve():
    from app import app as ocr_app

    return ocr_app
