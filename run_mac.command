#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

export HF_HUB_DISABLE_XET="1"
export PYTORCH_ENABLE_MPS_FALLBACK="1"

if [ ! -f ".venv/bin/python" ]; then
    echo "========================================================"
    echo "  First-time setup on Mac (Apple Silicon M1/M2/M3/M4)"
    echo "========================================================"
    python3 -m venv .venv
    ./.venv/bin/python -m pip install --upgrade pip
    echo "Installing Apple Silicon (MPS) PyTorch and dependencies..."
    ./.venv/bin/pip install torch torchvision
    ./.venv/bin/pip install -r requirements.txt
fi

echo "========================================================"
echo "  Starting Khmer PaddleOCR-VL Studio on port 7860..."
echo "  URL: http://localhost:7860"
echo "========================================================"
./.venv/bin/python app.py
