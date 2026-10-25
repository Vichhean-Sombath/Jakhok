@echo off
title Khmer PaddleOCR-VL Studio (OpenKhmer Vision+Language LoRA)
cd /d "%~dp0"
set HF_HUB_DISABLE_XET=1

if not exist ".venv\Scripts\python.exe" (
    echo ========================================================
    echo   First-time setup: Creating Python virtual environment
    echo ========================================================
    python -m venv .venv
    .\.venv\Scripts\python.exe -m pip install --upgrade pip
    echo Installing PyTorch with CUDA support...
    .\.venv\Scripts\pip.exe install torch torchvision --index-url https://download.pytorch.org/whl/cu124
    echo Installing project dependencies...
    .\.venv\Scripts\pip.exe install -r requirements.txt
)

echo ========================================================
echo   Starting Khmer PaddleOCR-VL Studio on port 7860...
echo   URL: http://localhost:7860
echo ========================================================
.\.venv\Scripts\python.exe app.py
pause
