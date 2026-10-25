"""
Utility script to:
1. Merge the 93,500-step LoRA adapter into the base `unsloth/PaddleOCR-VL` model (`merge_and_unload()`)
2. Save the standalone merged model locally (`./merged_model`) and/or push to Hugging Face Hub.
"""
import argparse
import os
import pathlib

from dotenv import load_dotenv

PROJECT_ROOT = pathlib.Path(__file__).resolve().parent
load_dotenv(PROJECT_ROOT / ".env", override=False)
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"

import torch
from peft import PeftModel
from transformers import AutoProcessor, PaddleOCRVLForConditionalGeneration

BASE_MODEL_ID = "unsloth/PaddleOCR-VL"
DEFAULT_HF_WRITE_TOKEN = os.environ.get("HF_WRITE_TOKEN") or None
DEFAULT_ADAPTER_DIR = str(
    pathlib.Path(__file__).parent / "checkpoints" / "checkpoint-119114-adapter"
)


def main():
    parser = argparse.ArgumentParser(description="Merge Khmer PaddleOCR-VL LoRA checkpoint")
    parser.add_argument(
        "--adapter",
        default=DEFAULT_ADAPTER_DIR,
        help="Path or HF repo ID of the LoRA adapter",
    )
    parser.add_argument(
        "--output-dir",
        default="merged_model",
        help="Local directory to save the merged 16-bit model",
    )
    parser.add_argument(
        "--push-to-hub",
        default=None,
        help="Optional HF repo ID to push the merged model (e.g., dvdphobia/Khmer-PaddleOCR-VL-Merged)",
    )
    parser.add_argument(
        "--token",
        default=DEFAULT_HF_WRITE_TOKEN,
        help="Explicit write token (prefer HF_WRITE_TOKEN in .env to avoid shell history)",
    )
    args = parser.parse_args()

    if args.push_to_hub and not args.token:
        parser.error("Set HF_WRITE_TOKEN in .env before pushing to the Hub.")

    print(f"[1/4] Loading processor from {BASE_MODEL_ID}...")
    processor = AutoProcessor.from_pretrained(BASE_MODEL_ID, trust_remote_code=True)

    print(f"[2/4] Loading base model {BASE_MODEL_ID} in bfloat16...")
    base_model = PaddleOCRVLForConditionalGeneration.from_pretrained(
        BASE_MODEL_ID,
        torch_dtype=torch.bfloat16,
        low_cpu_mem_usage=True,
    )

    print(f"[3/4] Applying and merging LoRA adapter from {args.adapter}...")
    peft_model = PeftModel.from_pretrained(base_model, args.adapter)
    merged_model = peft_model.merge_and_unload()

    print(f"[4/4] Saving merged standalone model to {args.output_dir}...")
    os.makedirs(args.output_dir, exist_ok=True)
    merged_model.save_pretrained(args.output_dir, safe_serialization=True)
    processor.save_pretrained(args.output_dir)
    print(f"Successfully saved merged model to: {os.path.abspath(args.output_dir)}")

    if args.push_to_hub:
        print(f"Pushing merged model to Hugging Face Hub: {args.push_to_hub}...")
        merged_model.push_to_hub(args.push_to_hub, token=args.token, safe_serialization=True)
        processor.push_to_hub(args.push_to_hub, token=args.token)
        print(f"Successfully pushed to https://huggingface.co/{args.push_to_hub}")


if __name__ == "__main__":
    main()
