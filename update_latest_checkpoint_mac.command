#!/usr/bin/env bash
set -e
cd "$(dirname "$0")"

export HF_HUB_DISABLE_XET="1"
export PYTORCH_ENABLE_MPS_FALLBACK="1"
export AUTO_PULL_LATEST_CHECKPOINT="1"

bash ./run_mac.command
