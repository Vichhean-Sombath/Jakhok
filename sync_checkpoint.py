#!/usr/bin/env python3
"""Sync and activate a private OpenKhmer checkpoint without starting the app."""
from __future__ import annotations

import argparse
import os
from pathlib import Path

from dotenv import load_dotenv

from checkpoint_sync import (
    DEFAULT_A100_RUN_ID,
    CheckpointSyncError,
    import_local_checkpoint,
    sync_latest_checkpoint,
)


PROJECT_ROOT = Path(__file__).resolve().parent


def main() -> int:
    load_dotenv(PROJECT_ROOT / ".env", override=False)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", default=os.environ.get("PRIVATE_RUN_ID", DEFAULT_A100_RUN_ID))
    parser.add_argument(
        "--repo-id",
        default=os.environ.get("PRIVATE_CHECKPOINT_REPO", "dvdphobia/OpenKhmer-Private-Checkpoints"),
    )
    parser.add_argument("--base-model-id", default=os.environ.get("BASE_MODEL_ID", "unsloth/PaddleOCR-VL"))
    parser.add_argument("--checkpoints-dir", type=Path, default=PROJECT_ROOT / "checkpoints")
    parser.add_argument(
        "--local-checkpoint", type=Path,
        help="Import a local checkpoint directory containing state.json and adapter/ without HF access.",
    )
    parser.add_argument(
        "--source-identity",
        help="Non-secret provenance label for --local-checkpoint (for example, a Modal Volume checkpoint path).",
    )
    args = parser.parse_args()

    try:
        if args.local_checkpoint:
            manifest = import_local_checkpoint(
                checkpoint_dir=args.local_checkpoint,
                run_id=args.run_id,
                checkpoints_root=args.checkpoints_dir,
                base_model_id=args.base_model_id,
                source_identity=args.source_identity,
            )
        else:
            manifest = sync_latest_checkpoint(
                repo_id=args.repo_id,
                run_id=args.run_id,
                token=os.environ.get("HF_PRIVATE_CHECKPOINT_TOKEN") or None,
                checkpoints_root=args.checkpoints_dir,
                base_model_id=args.base_model_id,
            )
    except CheckpointSyncError as exc:
        parser.exit(1, f"Checkpoint sync failed: {exc}\n")
    except Exception as exc:
        # Never print environment values or downloader exception text, which may
        # contain request details. The exception class identifies the failure.
        parser.exit(1, f"Checkpoint sync failed ({type(exc).__name__}); no model was activated.\n")

    provenance = (
        f"HF revision={manifest['repo_revision']}"
        if manifest.get("source_type", "hf") == "hf"
        else f"source={manifest['source_identity']}"
    )
    print(
        "Activated checkpoint: "
        f"run={manifest['run_id']} phase_step={manifest['optimizer_step']} "
        f"parent_run={manifest.get('parent_run_id')} "
        f"parent_step={manifest.get('parent_optimizer_step')} "
        f"{provenance}"
    )
    print(f"Local manifest: {args.checkpoints_dir / 'active_checkpoint.json'}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
