import asyncio
import base64
import contextlib
import io
import json
import logging
import os
import pathlib
import threading
import time
from typing import Optional

from dotenv import load_dotenv

# Load project-local secrets before importing Hugging Face libraries.
PROJECT_ROOT = pathlib.Path(__file__).resolve().parent
load_dotenv(PROJECT_ROOT / ".env", override=False)

# Disable hf-xet chunked downloader which can hang on Windows / Cloudflare WARP
os.environ.setdefault("HF_HUB_DISABLE_XET", "1")
# Public model downloads do not need the user's cached Hub token. Private access
# is supplied explicitly below through HF_PRIVATE_CHECKPOINT_TOKEN.
os.environ["HF_HUB_DISABLE_IMPLICIT_TOKEN"] = "1"
# Enable automatic CPU fallback for any unimplemented Metal (MPS) shader ops on Apple Silicon (M1-M4)
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

import numpy as np
import torch
from fastapi import Body, FastAPI, File, Form, HTTPException, UploadFile
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, JSONResponse, Response, StreamingResponse
from fastapi.staticfiles import StaticFiles
from PIL import Image, ImageFilter, ImageOps

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
)
logger = logging.getLogger("khmer-ocr-app")

BASE_MODEL_ID = os.environ.get("BASE_MODEL_ID", "unsloth/PaddleOCR-VL")
HF_PRIVATE_CHECKPOINT_TOKEN = os.environ.get("HF_PRIVATE_CHECKPOINT_TOKEN") or None

PRIVATE_CHECKPOINT_REPO = os.environ.get(
    "PRIVATE_CHECKPOINT_REPO", "dvdphobia/OpenKhmer-Private-Checkpoints"
)
PRIVATE_RUN_ID = os.environ.get("PRIVATE_RUN_ID", "d84cd55f108195b1")
_CHECKPOINTS_ROOT = pathlib.Path(__file__).parent / "checkpoints"


def _build_or_get_ema_soup_adapter() -> Optional[ tuple[pathlib.Path, str] ]:
    """
    Combines available Vision+Language LoRA checkpoints (576-tensor adapters) using
    Exponential / Weighted Model Souping so single-step high-LR oscillations cancel out.
    """
    if not _CHECKPOINTS_ROOT.exists():
        return None
    try:
        from safetensors.torch import load_file, save_file

        vision_ckpts: list[tuple[int, pathlib.Path]] = []
        for d in _CHECKPOINTS_ROOT.iterdir():
            if not d.is_dir() or "soup" in d.name:
                continue
            sf = d / "adapter_model.safetensors"
            cfg = d / "adapter_config.json"
            if sf.exists() and cfg.exists():
                parts = d.name.split("-")
                step_num = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
                if step_num >= 110000:
                    vision_ckpts.append((step_num, d))

        if len(vision_ckpts) < 2:
            return None

        vision_ckpts.sort(key=lambda x: x[0])
        max_step = vision_ckpts[-1][0]
        soup_dir = _CHECKPOINTS_ROOT / "checkpoint-ema-soup-adapter"
        stamp_file = soup_dir / "soup_meta.json"
        source_steps = [s for s, _ in vision_ckpts]

        if (soup_dir / "adapter_model.safetensors").exists() and stamp_file.exists():
            try:
                meta = json.loads(stamp_file.read_text(encoding="utf-8"))
                if meta.get("source_steps") == source_steps:
                    return (
                        soup_dir,
                        f"OpenKhmer {max_step / 1000:.1f}k EMA-Soup Vision+Language LoRA ({len(source_steps)} ckpts)",
                    )
            except Exception:
                pass

        # Anchor checkpoints that excelled across printed, org-chart, handwritten, and poem domains
        preferred_weights = {
            110000: 0.18,
            119114: 0.22,
            122000: 0.35,
            133000: 0.15,
            134000: 0.10,
        }
        weighted_list: list[tuple[float, pathlib.Path, int]] = []
        for step_num, d in vision_ckpts:
            w = preferred_weights.get(step_num, 0.12 if step_num == max_step else 0.05)
            weighted_list.append((w, d, step_num))

        total_w = sum(w for w, _, _ in weighted_list)
        weighted_list = [(w / total_w, d, s) for w, d, s in weighted_list]

        soup_dir.mkdir(parents=True, exist_ok=True)
        latest_dir = vision_ckpts[-1][1]
        import shutil

        for item in latest_dir.iterdir():
            if item.is_file() and item.name != "adapter_model.safetensors":
                shutil.copy2(item, soup_dir / item.name)

        loaded = [(load_file(str(d / "adapter_model.safetensors")), w) for w, d, _ in weighted_list]
        avg_tensors = {}
        first_tensors = loaded[0][0]
        for k in first_tensors.keys():
            acc = sum(t_dict[k].float() * w for t_dict, w in loaded)
            avg_tensors[k] = acc.to(first_tensors[k].dtype)

        save_file(avg_tensors, str(soup_dir / "adapter_model.safetensors"))
        stamp_file.write_text(
            json.dumps({"source_steps": source_steps, "max_step": max_step}, indent=2),
            encoding="utf-8",
        )
        return (
            soup_dir,
            f"OpenKhmer {max_step / 1000:.1f}k EMA-Soup Vision+Language LoRA ({len(source_steps)} ckpts)",
        )
    except Exception as exc:
        logger.warning(f"EMA soup build skipped: {exc}")
        return None


def _find_highest_local_adapter() -> pathlib.Path:
    if _CHECKPOINTS_ROOT.exists():
        candidates: list[tuple[int, pathlib.Path]] = []
        for d in _CHECKPOINTS_ROOT.iterdir():
            if d.is_dir() and "soup" not in d.name and (d / "adapter_model.safetensors").exists():
                parts = d.name.split("-")
                step_num = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 0
                candidates.append((step_num, d))
        if candidates:
            candidates.sort(key=lambda x: x[0], reverse=True)
            return candidates[0][1]
    return _CHECKPOINTS_ROOT / "checkpoint-134000-adapter"


def ensure_latest_private_adapter() -> tuple[str, str]:
    """
    Ensures the private OpenKhmer Vision+Language LoRA checkpoint is available locally.
    If `AUTO_PULL_LATEST_CHECKPOINT=1` is set or the local adapter directory is missing,
    it automatically downloads `runs/<PRIVATE_RUN_ID>/checkpoint-latest` using
    `HF_PRIVATE_CHECKPOINT_TOKEN` from the local `.env` file.
    """
    auto_pull = os.environ.get("AUTO_PULL_LATEST_CHECKPOINT", "0") == "1"
    best_local = _find_highest_local_adapter()
    if not auto_pull and (best_local / "adapter_model.safetensors").exists():
        soup = _build_or_get_ema_soup_adapter()
        if soup is not None:
            return str(soup[0]), soup[1]
        parts = best_local.name.split("-")
        step_val = int(parts[1]) if len(parts) >= 2 and parts[1].isdigit() else 134000
        return (
            str(best_local),
            f"OpenKhmer {step_val / 1000:.1f}k-step Vision+Language LoRA ({best_local.name})",
        )

    try:
        import shutil
        from huggingface_hub import hf_hub_download, snapshot_download

        prefix = f"runs/{PRIVATE_RUN_ID}/checkpoint-latest"
        state_path = hf_hub_download(
            repo_id=PRIVATE_CHECKPOINT_REPO,
            repo_type="model",
            filename=f"{prefix}/state.json",
            token=HF_PRIVATE_CHECKPOINT_TOKEN or False,
            force_download=True,
        )
        state = json.loads(pathlib.Path(state_path).read_text(encoding="utf-8"))
        step = int(state.get("optimizer_step", 119114))
        target_dir = _CHECKPOINTS_ROOT / f"checkpoint-{step}-adapter"
        if not (target_dir / "adapter_model.safetensors").exists():
            logger.info(
                f"Downloading private checkpoint step {step} from {PRIVATE_CHECKPOINT_REPO}..."
            )
            dl_root = pathlib.Path(
                snapshot_download(
                    repo_id=PRIVATE_CHECKPOINT_REPO,
                    repo_type="model",
                    allow_patterns=[f"{prefix}/adapter/*", f"{prefix}/state.json"],
                    token=HF_PRIVATE_CHECKPOINT_TOKEN or False,
                    force_download=True,
                )
            )
            src_adapter = dl_root / prefix / "adapter"
            target_dir.mkdir(parents=True, exist_ok=True)
            for item in src_adapter.iterdir():
                if item.is_file():
                    shutil.copy2(item, target_dir / item.name)
            shutil.copy2(dl_root / prefix / "state.json", target_dir / "state.json")
        soup = _build_or_get_ema_soup_adapter()
        if soup is not None:
            return str(soup[0]), soup[1]
        return (
            str(target_dir),
            f"OpenKhmer {step / 1000:.1f}k-step Vision+Language LoRA (checkpoint-{step})",
        )
    except Exception as exc:
        logger.warning(f"Private checkpoint sync fallback: {exc}")
        if (best_local / "adapter_model.safetensors").exists():
            return (
                str(best_local),
                f"OpenKhmer Vision+Language LoRA ({best_local.name})",
            )
        return ("dvdphobia/Khmer-PaddleOCR-VL-LoRA", "dvdphobia/Khmer-PaddleOCR-VL-LoRA")


_RESOLVED_ADAPTER_PATH, _RESOLVED_DISPLAY_NAME = ensure_latest_private_adapter()
LORA_MODEL_ID = os.environ.get("LORA_MODEL_ID", _RESOLVED_ADAPTER_PATH)
LORA_DISPLAY_NAME = (
    _RESOLVED_DISPLAY_NAME
    if LORA_MODEL_ID == _RESOLVED_ADAPTER_PATH
    else LORA_MODEL_ID
)
DOCLAYOUT_MODEL_ID = os.environ.get(
    "DOCLAYOUT_MODEL_ID", "PaddlePaddle/PP-DocLayoutV2_safetensors"
)
PORT = int(os.environ.get("PORT", "7860"))

TASK_PROMPTS = {
    "ocr": "OCR:",
    "table": "Table Recognition:",
    "formula": "Formula Recognition:",
    "chart": "Chart Recognition:",
    "detection": "Text Detection:",
}

LAYOUT_LABEL_TO_PROMPT = {
    "formula": "Formula Recognition:",
    "display_formula": "Formula Recognition:",
    "inline_formula": "Formula Recognition:",
}

FORMULA_LABELS = {"formula", "display_formula", "inline_formula"}


def _contains_khmer(text: str) -> bool:
    return any("\u1780" <= ch <= "\u17ff" for ch in text)


def _box_iou(b1: list[int], b2: list[int]) -> float:
    x1 = max(b1[0], b2[0])
    y1 = max(b1[1], b2[1])
    x2 = min(b1[2], b2[2])
    y2 = min(b1[3], b2[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    if inter <= 0:
        return 0.0
    a1 = max(1, (b1[2] - b1[0]) * (b1[3] - b1[1]))
    a2 = max(1, (b2[2] - b2[0]) * (b2[3] - b2[1]))
    return inter / float(min(a1, a2))


def _detect_best_device() -> str:
    if torch.cuda.is_available():
        return "cuda"
    if hasattr(torch.backends, "mps") and torch.backends.mps.is_available():
        return "mps"
    return "cpu"


class TextDetectorEngine:
    """
    Smart Hybrid Detector combining:
    1. `PP-OCRv4_det` (DBNet) with Khmer-aware padding, horizontal fragment merging, and multi-column/row sorting
    2. `PaddlePaddle/PP-DocLayoutV2_safetensors` with NMS deduplication & column-aware reading order
    """

    def __init__(self) -> None:
        self._doclayout_model = None
        self._doclayout_processor = None
        self._doclayout_device = _detect_best_device()
        self._det_standard = None
        self._det_dense = None
        self._lock = threading.Lock()

    def _ensure_doclayout_initialized(self) -> None:
        if self._doclayout_model is not None:
            return
        with self._lock:
            if self._doclayout_model is not None:
                return
            from transformers import AutoImageProcessor, AutoModelForObjectDetection

            logger.info(f"Loading official Stage-1 detector {DOCLAYOUT_MODEL_ID}...")
            self._doclayout_processor = AutoImageProcessor.from_pretrained(
                DOCLAYOUT_MODEL_ID
            )
            self._doclayout_model = (
                AutoModelForObjectDetection.from_pretrained(DOCLAYOUT_MODEL_ID)
                .to(self._doclayout_device)
                .eval()
            )
            logger.info(f"Loaded {DOCLAYOUT_MODEL_ID} on {self._doclayout_device}")

    def _ensure_dbnet_initialized(self) -> None:
        if self._det_standard is not None:
            return
        with self._lock:
            if self._det_standard is not None:
                return
            from rapidocr_onnxruntime import RapidOCR

            self._det_standard = RapidOCR(
                det_limit_side_len=1600,
                det_limit_type="max",
                det_db_thresh=0.24,
                det_db_box_thresh=0.38,
                det_db_unclip_ratio=1.95,
            )
            self._det_dense = RapidOCR(
                det_limit_side_len=2048,
                det_limit_type="max",
                det_db_thresh=0.16,
                det_db_box_thresh=0.26,
                det_db_unclip_ratio=2.1,
            )

    @staticmethod
    def _group_into_horizontal_rows(boxes: list[dict]) -> list[list[dict]]:
        """Groups boxes into horizontal rows sorted strictly top-to-bottom, and left-to-right within each row."""
        boxes_sorted_y = sorted(
            boxes, key=lambda b: (b["bbox"][1] + b["bbox"][3]) / 2.0
        )
        rows: list[list[dict]] = []
        for b in boxes_sorted_y:
            cy = (b["bbox"][1] + b["bbox"][3]) / 2.0
            bh = max(1, b["bbox"][3] - b["bbox"][1])
            placed = False
            for row in rows:
                row_cy = sum(
                    (r["bbox"][1] + r["bbox"][3]) / 2.0 for r in row
                ) / len(row)
                row_bh = sum(
                    max(1, r["bbox"][3] - r["bbox"][1]) for r in row
                ) / len(row)
                if abs(cy - row_cy) < max(bh, row_bh) * 0.55:
                    row.append(b)
                    placed = True
                    break
            if not placed:
                rows.append([b])

        rows.sort(
            key=lambda row: sum((r["bbox"][1] + r["bbox"][3]) / 2.0 for r in row)
            / len(row)
        )
        for row in rows:
            row.sort(key=lambda b: b["bbox"][0])
        return rows

    @classmethod
    def _merge_horizontal_line_fragments(
        cls, boxes: list[dict], image_width: int
    ) -> list[dict]:
        """Merges adjacent horizontal word/punctuation fragments within each horizontal row."""
        if len(boxes) <= 1:
            return boxes

        rows = cls._group_into_horizontal_rows(boxes)
        merged: list[dict] = []

        for row in rows:
            row_merged: list[dict] = []
            for b in row:
                if not row_merged:
                    row_merged.append(b)
                    continue

                prev = row_merged[-1]
                px1, py1, px2, py2 = prev["bbox"]
                bx1, by1, bx2, by2 = b["bbox"]
                pw = max(1, px2 - px1)
                bw = max(1, bx2 - bx1)
                ph = max(1, py2 - py1)
                bh = max(1, by2 - by1)

                y_overlap = min(py2, by2) - max(py1, by1)
                same_line = y_overlap > 0.35 * min(ph, bh)
                horiz_gap = bx1 - px2
                is_small_punct = (pw <= ph * 1.45) or (bw <= bh * 1.45)
                max_gap = max(ph, bh) * (1.85 if is_small_punct else 0.70)
                min_gap = -min(pw, bw) if is_small_punct else -0.35 * min(ph, bh)
                both_long_clauses = (pw > ph * 2.2) and (bw > bh * 2.2)
                near_center_gutter = (
                    both_long_clauses
                    and (image_width * 0.42 <= px2 <= image_width * 0.58)
                    and (image_width * 0.44 <= bx1 <= image_width * 0.60)
                )

                if (
                    same_line
                    and not near_center_gutter
                    and min_gap <= horiz_gap <= max_gap
                    and (max(px2, bx2) - min(px1, bx1)) < image_width * 0.92
                ):
                    nx1 = min(px1, bx1)
                    ny1 = min(py1, by1)
                    nx2 = max(px2, bx2)
                    ny2 = max(py2, by2)
                    prev["bbox"] = [nx1, ny1, nx2, ny2]
                    prev["polygon"] = [
                        [nx1, ny1],
                        [nx2, ny1],
                        [nx2, ny2],
                        [nx1, ny2],
                    ]
                else:
                    row_merged.append(b)
            merged.extend(row_merged)

        return merged

    @classmethod
    def _expand_line_punctuation_margins(
        cls, boxes: list[dict], image: Image.Image
    ) -> list[dict]:
        """
        Expands horizontal line boxes slightly left/right if isolated leading bullets (e.g. '$', '-')
        or trailing Khmer punctuation (e.g. '។', 'ៗ') sit on the exact same baseline.
        """
        if not boxes:
            return boxes
        import cv2

        w, h = image.size
        gray = cv2.cvtColor(np.array(image), cv2.COLOR_RGB2GRAY)
        rows = cls._group_into_horizontal_rows(boxes)
        out: list[dict] = []

        for row in rows:
            for i, b in enumerate(row):
                bx1, by1, bx2, by2 = b["bbox"]
                bh = max(1, by2 - by1)
                y_top = min(h - 1, max(0, by1 + int(bh * 0.14)))
                y_bot = max(y_top + 1, min(h, by2 - int(bh * 0.14)))
                band_h = max(1, y_bot - y_top)

                # Safe left/right search limits that never cross into neighbor boxes
                left_limit = (
                    max(0, bx1 - min(42, int(bh * 1.25)))
                    if i == 0
                    else max(row[i - 1]["bbox"][2] + 4, bx1 - min(28, int(bh * 0.85)))
                )
                right_limit = (
                    min(w, bx2 + min(52, int(bh * 1.50)))
                    if i == len(row) - 1
                    else min(row[i + 1]["bbox"][0] - 4, bx2 + min(28, int(bh * 0.85)))
                )

                if left_limit < bx1:
                    l_band = gray[y_top:y_bot, left_limit:bx1]
                    dark_cols = (l_band < 200).sum(axis=0)
                    # Punctuation/bullet columns have ink (>=2px) but are not solid vertical border lines (<70% height)
                    valid_cols = np.where(
                        (dark_cols >= 2) & (dark_cols <= max(3, int(band_h * 0.70)))
                    )[0]
                    if len(valid_cols) >= 2:
                        bx1 = max(0, left_limit + int(valid_cols[0]) - 4)

                if right_limit > bx2:
                    r_band = gray[y_top:y_bot, bx2:right_limit]
                    dark_cols = (r_band < 200).sum(axis=0)
                    valid_cols = np.where(
                        (dark_cols >= 2) & (dark_cols <= max(3, int(band_h * 0.70)))
                    )[0]
                    if len(valid_cols) >= 2:
                        bx2 = min(w, bx2 + int(valid_cols[-1]) + 5)

                b["bbox"] = [bx1, by1, bx2, by2]
                b["polygon"] = [
                    [bx1, by1],
                    [bx2, by1],
                    [bx2, by2],
                    [bx1, by2],
                ]
                out.append(b)

        return out

    @classmethod
    def _sort_boxes_reading_order(
        cls,
        boxes: list[dict],
        image_width: int = 1000,
        allow_two_column: bool = False,
    ) -> list[dict]:
        if not boxes:
            return []

        def _sort_single_column(col_boxes: list[dict]) -> list[dict]:
            rows = cls._group_into_horizontal_rows(col_boxes)
            return [b for row in rows for b in row]

        if allow_two_column:
            mid_x = image_width / 2.0
            left_col = [b for b in boxes if b["bbox"][2] < mid_x * 1.04]
            right_col = [b for b in boxes if b["bbox"][0] > mid_x * 0.96]
            spanning = [
                b for b in boxes if b not in left_col and b not in right_col
            ]
            if (
                len(left_col) >= 4
                and len(right_col) >= 4
                and len(spanning) <= max(3, int(0.2 * len(boxes)))
            ):
                col_boxes_all = left_col + right_col
                min_col_y = min(b["bbox"][1] for b in col_boxes_all)
                max_col_y = max(b["bbox"][3] for b in col_boxes_all)
                mid_col_y = (min_col_y + max_col_y) / 2.0
                top_spanning = [
                    b
                    for b in spanning
                    if (b["bbox"][1] + b["bbox"][3]) / 2.0 <= mid_col_y
                ]
                bottom_spanning = [
                    b for b in spanning if b not in top_spanning
                ]
                ordered = (
                    _sort_single_column(top_spanning)
                    + _sort_single_column(left_col)
                    + _sort_single_column(right_col)
                    + _sort_single_column(bottom_spanning)
                )
            else:
                ordered = _sort_single_column(boxes)
        else:
            ordered = _sort_single_column(boxes)

        for idx, item in enumerate(ordered):
            item["id"] = idx + 1
        return ordered

    def _detect_pp_doclayout_v2(
        self, image: Image.Image, threshold: float = 0.42
    ) -> list[dict]:
        self._ensure_doclayout_initialized()
        w, h = image.size

        inputs = self._doclayout_processor(images=image, return_tensors="pt")
        try:
            dev_inputs = {
                k: v.to(self._doclayout_device) if isinstance(v, torch.Tensor) else v
                for k, v in inputs.items()
            }
            with self._lock, torch.inference_mode():
                outputs = self._doclayout_model(**dev_inputs)
        except Exception as mps_exc:
            if self._doclayout_device == "mps":
                logger.warning(
                    f"PP-DocLayoutV2 MPS fallback to CPU ({mps_exc})"
                )
                self._doclayout_device = "cpu"
                self._doclayout_model = self._doclayout_model.to("cpu")
                dev_inputs = {
                    k: v.to("cpu") if isinstance(v, torch.Tensor) else v
                    for k, v in inputs.items()
                }
                with self._lock, torch.inference_mode():
                    outputs = self._doclayout_model(**dev_inputs)
            else:
                raise

        results = self._doclayout_processor.post_process_object_detection(
            outputs, target_sizes=[(h, w)], threshold=threshold
        )[0]

        id2label = self._doclayout_model.config.id2label
        candidates: list[dict] = []

        for score_t, label_t, box_t in zip(
            results["scores"], results["labels"], results["boxes"]
        ):
            score = float(score_t.item())
            label_id = int(label_t.item())
            label_name = id2label.get(label_id, f"class_{label_id}")

            if label_name in {"header_image", "footer_image"}:
                continue

            x1, y1, x2, y2 = [float(v) for v in box_t.tolist()]
            bx1 = max(0, int(round(x1 - 4)))
            by1 = max(0, int(round(y1 - 4)))
            bx2 = min(w, int(round(x2 + 4)))
            by2 = min(h, int(round(y2 + 4)))

            if (bx2 - bx1) < 10 or (by2 - by1) < 10:
                continue

            candidates.append(
                {
                    "id": 0,
                    "label": label_name,
                    "score": round(score, 3),
                    "bbox": [bx1, by1, bx2, by2],
                    "polygon": [
                        [bx1, by1],
                        [bx2, by1],
                        [bx2, by2],
                        [bx1, by2],
                    ],
                }
            )

        # Apply Non-Maximum Suppression (NMS) so duplicate overlapping boxes are removed
        candidates.sort(key=lambda c: c["score"], reverse=True)
        kept: list[dict] = []
        for cand in candidates:
            if any(_box_iou(cand["bbox"], k["bbox"]) > 0.55 for k in kept):
                continue
            kept.append(cand)

        return self._sort_boxes_reading_order(
            kept, image_width=w, allow_two_column=True
        )

    def _detect_dbnet(
        self, image: Image.Image, mode: str = "standard", merge_fragments: bool = False
    ) -> list[dict]:
        self._ensure_dbnet_initialized()
        w, h = image.size

        border_pad = 12
        padded_img = ImageOps.expand(image, border=border_pad, fill=(255, 255, 255))
        pw, ph = padded_img.size

        scale = 1.0
        work_img = padded_img
        min_dim = min(w, h)
        if mode == "dense" and max(w, h) < 1600:
            scale = 2.0
            work_img = padded_img.resize(
                (int(pw * scale), int(ph * scale)), Image.Resampling.LANCZOS
            )
        elif min_dim < 600:
            scale = 1.5
            work_img = padded_img.resize(
                (int(pw * scale), int(ph * scale)), Image.Resampling.LANCZOS
            )

        img_np = np.array(work_img)
        detector = self._det_dense if mode == "dense" else self._det_standard

        with self._lock:
            raw_boxes, _ = detector(img_np, use_det=True, use_cls=False, use_rec=False)

        parsed_boxes: list[dict] = []
        if raw_boxes is not None and len(raw_boxes) > 0:
            for poly in raw_boxes:
                pts = [
                    [
                        float(pt[0]) / scale - border_pad,
                        float(pt[1]) / scale - border_pad,
                    ]
                    for pt in poly
                ]
                xs = [p[0] for p in pts]
                ys = [p[1] for p in pts]
                x1, y1, x2, y2 = min(xs), min(ys), max(xs), max(ys)
                bw = x2 - x1
                bh = y2 - y1
                if bw < 5 or bh < 5:
                    continue

                pad_x = max(4, int(bh * 0.20))
                pad_y = max(4, int(bh * 0.25))
                bx1 = max(0, int(round(x1 - pad_x)))
                by1 = max(0, int(round(y1 - pad_y)))
                bx2 = min(w, int(round(x2 + pad_x)))
                by2 = min(h, int(round(y2 + pad_y)))

                parsed_boxes.append(
                    {
                        "id": 0,
                        "label": "text_line",
                        "score": 1.0,
                        "bbox": [bx1, by1, bx2, by2],
                        "polygon": [[round(p[0], 1), round(p[1], 1)] for p in pts],
                    }
                )

        if merge_fragments:
            parsed_boxes = self._merge_horizontal_line_fragments(parsed_boxes, w)
            parsed_boxes = self._expand_line_punctuation_margins(parsed_boxes, image)

        return self._sort_boxes_reading_order(
            parsed_boxes, image_width=w, allow_two_column=False
        )

    def detect(self, image: Image.Image, mode: str = "smart_hybrid") -> dict:
        t0 = time.perf_counter()
        w, h = image.size

        if mode == "none":
            return {
                "mode": "none",
                "elapsed_ms": 0.1,
                "image_size": {"width": w, "height": h},
                "boxes": [
                    {
                        "id": 1,
                        "label": "full_image",
                        "score": 1.0,
                        "bbox": [0, 0, w, h],
                        "polygon": [[0, 0], [w, 0], [w, h], [0, h]],
                    }
                ],
            }

        ordered_boxes: list[dict] = []

        if mode == "smart_hybrid":
            # Run both DBNet and PP-DocLayoutV2 to pick the optimal segmentation:
            # - Academic / Formula document: use deduplicated PP-DocLayoutV2 blocks (paragraphs + formulas)
            # - Table, Org Chart, or Handwritten page: use merged DBNet single-line boxes
            layout_boxes = self._detect_pp_doclayout_v2(image, threshold=0.38)
            dbnet_boxes = self._detect_dbnet(image, mode="standard", merge_fragments=True)

            formula_boxes = [
                b
                for b in layout_boxes
                if b["label"] in FORMULA_LABELS
            ]

            if formula_boxes and len(layout_boxes) >= 4:
                # Academic / Formula document: use deduplicated layout blocks (text + formulas)
                ordered_boxes = [
                    b for b in layout_boxes if b["label"] != "image"
                ]
            else:
                # Document, Table, Org Chart, or Handwritten page: use merged DBNet lines
                # because the Khmer LoRA model is trained on single-line crops!
                ordered_boxes = dbnet_boxes
        elif mode == "pp_doclayout_v2":
            ordered_boxes = [
                b
                for b in self._detect_pp_doclayout_v2(image, threshold=0.42)
                if b["label"] != "image"
            ]
            if not ordered_boxes:
                ordered_boxes = self._detect_dbnet(image, mode="standard", merge_fragments=True)
        elif mode == "standard":
            ordered_boxes = self._detect_dbnet(image, mode="standard", merge_fragments=True)
        else:
            ordered_boxes = self._detect_dbnet(image, mode=mode, merge_fragments=False)

        if not ordered_boxes:
            ordered_boxes = [
                {
                    "id": 1,
                    "label": "full_image",
                    "score": 1.0,
                    "bbox": [0, 0, w, h],
                    "polygon": [[0, 0], [w, 0], [w, h], [0, h]],
                }
            ]

        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        return {
            "mode": mode,
            "elapsed_ms": elapsed_ms,
            "image_size": {"width": w, "height": h},
            "boxes": ordered_boxes,
        }

    @staticmethod
    def crop_and_enhance(
        image: Image.Image, bbox: list[int], box_label: str = "text_line"
    ) -> tuple[Image.Image, str]:
        import cv2

        x1, y1, x2, y2 = bbox
        crop = image.crop((x1, y1, x2, y2)).convert("RGB")
        cw, ch = crop.size

        thumb_buf = io.BytesIO()
        crop.save(thumb_buf, format="PNG")
        thumb_b64 = "data:image/png;base64," + base64.b64encode(
            thumb_buf.getvalue()
        ).decode("ascii")

        # Only strip continuous solid box/grid border lines in the outermost 3px (std < 35 and >92% dark)
        # Never touch text strokes (like '0000000000') which have alternating dark/white gaps!
        if box_label == "text_line" and ch > 18 and cw > 24 and ch < 72:
            arr = np.array(crop)
            gray = cv2.cvtColor(arr, cv2.COLOR_RGB2GRAY)
            modified = False
            for r in (0, 1, 2, ch - 3, ch - 2, ch - 1):
                if (gray[r, :] < 150).mean() > 0.92 and gray[r, :].std() < 35:
                    arr[r, :] = 255
                    modified = True
            for c in (0, 1, 2, cw - 3, cw - 2, cw - 1):
                if (gray[:, c] < 150).mean() > 0.92 and gray[:, c].std() < 35:
                    arr[:, c] = 255
                    modified = True
            if modified:
                crop = Image.fromarray(arr)

        # Upscale short line crops to 56px (exact 2x multiple of PaddleOCR-VL's 28px patch grid)
        target_min_h = 56
        if 0 < ch < target_min_h:
            upscale = min(3.5, float(target_min_h) / ch)
            crop = crop.resize(
                (max(28, int(round(cw * upscale))), max(28, int(round(ch * upscale)))),
                Image.Resampling.BICUBIC,
            )

        bordered = ImageOps.expand(crop, border=8, fill=(255, 255, 255))
        return bordered, thumb_b64


detector_engine = TextDetectorEngine()


class ModelManager:
    def __init__(self) -> None:
        self.model = None
        self.processor = None
        self.device: str = _detect_best_device()
        self.dtype: torch.dtype = self._detect_dtype()
        self.status: str = "initializing"
        self.status_message: str = "Waiting to load model..."
        self.error_detail: Optional[str] = None
        self.lock = threading.Lock()
        self.loaded_at: Optional[float] = None

    def _detect_dtype(self) -> torch.dtype:
        if self.device == "cuda" and torch.cuda.is_available():
            if torch.cuda.is_bf16_supported():
                return torch.bfloat16
            return torch.float16
        if self.device == "mps":
            try:
                _ = torch.zeros(1, device="mps", dtype=torch.bfloat16)
                return torch.bfloat16
            except Exception:
                return torch.float16
        return torch.float32

    def get_device_name(self) -> str:
        if self.device == "cuda" and torch.cuda.is_available():
            try:
                gpu_name = torch.cuda.get_device_name(0)
                vram_gb = torch.cuda.get_device_properties(0).total_memory / (1024**3)
                return f"{gpu_name} ({vram_gb:.1f} GB VRAM)"
            except Exception:
                return "CUDA GPU"
        if self.device == "mps":
            try:
                import subprocess

                chip = (
                    subprocess.check_output(
                        ["sysctl", "-n", "machdep.cpu.brand_string"],
                        stderr=subprocess.DEVNULL,
                    )
                    .decode("utf-8")
                    .strip()
                )
                return f"{chip} (Apple Metal MPS GPU)"
            except Exception:
                return "Apple Silicon (MPS GPU)"
        return "CPU"

    def load_model(self) -> None:
        if self.status == "ready" and self.model is not None:
            return

        with self.lock:
            if self.status == "ready" and self.model is not None:
                return

            self.status = "loading"
            self.error_detail = None
            t0 = time.time()

            try:
                from peft import PeftModel
                from transformers import AutoProcessor

                logger.info(
                    f"Loading processor from {BASE_MODEL_ID} (device={self.device}, dtype={self.dtype})..."
                )
                self.status_message = f"Loading processor ({BASE_MODEL_ID})..."

                try:
                    self.processor = AutoProcessor.from_pretrained(BASE_MODEL_ID)
                except Exception:
                    self.processor = AutoProcessor.from_pretrained(
                        BASE_MODEL_ID, trust_remote_code=True
                    )

                logger.info(f"Loading base model {BASE_MODEL_ID}...")
                self.status_message = f"Loading base model ({BASE_MODEL_ID})..."

                base_model = None
                try:
                    from transformers import PaddleOCRVLForConditionalGeneration

                    base_model = PaddleOCRVLForConditionalGeneration.from_pretrained(
                        BASE_MODEL_ID,
                        torch_dtype=self.dtype,
                        low_cpu_mem_usage=True,
                    )
                except Exception as e_native:
                    logger.warning(
                        f"Native PaddleOCRVLForConditionalGeneration load fallback: {e_native}"
                    )
                    from transformers import AutoModelForImageTextToText

                    base_model = AutoModelForImageTextToText.from_pretrained(
                        BASE_MODEL_ID,
                        torch_dtype=self.dtype,
                        low_cpu_mem_usage=True,
                        trust_remote_code=True,
                    )

                logger.info(
                    f"Loading LoRA adapter {LORA_DISPLAY_NAME} ({LORA_MODEL_ID})..."
                )
                self.status_message = f"Applying {LORA_DISPLAY_NAME}..."
                peft_model = PeftModel.from_pretrained(
                    base_model,
                    LORA_MODEL_ID,
                )

                self.status_message = f"Moving model to {self.device.upper()}..."
                peft_model = peft_model.to(device=self.device, dtype=self.dtype).eval()

                self.status_message = (
                    f"Loading Stage-1 Layout Detector ({DOCLAYOUT_MODEL_ID})..."
                )
                detector_engine._ensure_doclayout_initialized()
                detector_engine._ensure_dbnet_initialized()

                self.model = peft_model
                self.loaded_at = time.time()
                elapsed = self.loaded_at - t0
                self.status = "ready"
                self.status_message = (
                    f"Ready • {LORA_DISPLAY_NAME} + PP-DocLayoutV2 ({elapsed:.1f}s)"
                )
                logger.info(
                    f"Models successfully loaded in {elapsed:.2f}s on {self.device}"
                )

            except Exception as exc:
                self.status = "error"
                self.error_detail = str(exc)
                self.status_message = f"Failed to load model: {exc}"
                logger.exception("Error while loading OCR model")

    def prepare_inputs(self, image: Image.Image, prompt_text: str):
        messages = [
            {
                "role": "user",
                "content": [
                    {"type": "image", "image": image},
                    {"type": "text", "text": prompt_text},
                ],
            }
        ]
        inputs = self.processor.apply_chat_template(
            messages,
            tokenize=True,
            add_generation_prompt=True,
            return_dict=True,
            return_tensors="pt",
        )
        moved = {}
        for k, v in inputs.items():
            if isinstance(v, torch.Tensor):
                if v.is_floating_point():
                    moved[k] = v.to(device=self.device, dtype=self.dtype)
                else:
                    moved[k] = v.to(device=self.device)
            else:
                moved[k] = v
        return moved

    @staticmethod
    def clean_output_text(text: str, prompt_text: str) -> str:
        cleaned = text.strip()
        if "Assistant:" in cleaned:
            cleaned = cleaned.split("Assistant:", 1)[-1].strip()
        elif cleaned.startswith(f"User: {prompt_text}"):
            cleaned = cleaned[len(f"User: {prompt_text}") :].strip()
        return cleaned

    def predict(
        self,
        image: Image.Image,
        prompt_text: str = "OCR:",
        max_new_tokens: int = 1024,
        use_lora: bool = True,
    ) -> dict:
        if self.status != "ready" or self.model is None:
            raise RuntimeError(f"Model is not ready (status: {self.status_message})")

        t0 = time.perf_counter()
        inputs = self.prepare_inputs(image, prompt_text)
        input_len = inputs["input_ids"].shape[-1]

        adapter_ctx = (
            contextlib.nullcontext()
            if use_lora
            else self.model.disable_adapter()
        )

        with self.lock, adapter_ctx, torch.inference_mode():
            output_ids = self.model.generate(
                **inputs,
                max_new_tokens=max_new_tokens,
                do_sample=False,
                use_cache=True,
            )

        generated_ids = output_ids[:, input_len:]
        num_tokens = int(generated_ids.shape[-1])
        decoded = self.processor.batch_decode(
            generated_ids, skip_special_tokens=True
        )[0]
        cleaned_text = self.clean_output_text(decoded, prompt_text)

        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        tokens_per_sec = (
            round(num_tokens / (elapsed_ms / 1000.0), 1) if elapsed_ms > 0 else 0.0
        )

        return {
            "text": cleaned_text,
            "prompt": prompt_text,
            "use_lora": use_lora,
            "model_id": LORA_MODEL_ID if use_lora else BASE_MODEL_ID,
            "elapsed_ms": elapsed_ms,
            "tokens": num_tokens,
            "tokens_per_sec": tokens_per_sec,
            "image_size": {"width": image.width, "height": image.height},
        }

    def stream_regions_predict(
        self,
        image: Image.Image,
        prompt_text: str = "OCR:",
        max_new_tokens: int = 512,
        use_lora: bool = True,
        det_mode: str = "smart_hybrid",
    ):
        if self.status != "ready" or self.model is None:
            raise RuntimeError(f"Model is not ready (status: {self.status_message})")

        t0 = time.perf_counter()
        det_result = detector_engine.detect(image, mode=det_mode)
        boxes = det_result["boxes"]

        det_event = json.dumps(
            {
                "type": "detections",
                "boxes": boxes,
                "det_elapsed_ms": det_result["elapsed_ms"],
                "det_mode": det_mode,
            },
            ensure_ascii=False,
        )
        yield f"data: {det_event}\n\n"

        if det_mode == "none" or (
            len(boxes) == 1
            and boxes[0]["bbox"] == [0, 0, image.width, image.height]
        ):
            start_ev = json.dumps(
                {"type": "region_start", "index": 1, "total": 1, "box": boxes[0]},
                ensure_ascii=False,
            )
            yield f"data: {start_ev}\n\n"

            for chunk in self.stream_single_image(
                image, prompt_text, max_new_tokens, use_lora, boxes
            ):
                yield chunk
            return

        total_boxes = len(boxes)
        recognized_lines: list[str] = []
        region_results: list[dict] = []
        total_tokens = 0
        per_box_max_tokens = min(max_new_tokens, 384)
        page_has_khmer: Optional[bool] = None

        for idx, box in enumerate(boxes, start=1):
            box_label = box.get("label", "text_line")
            crop_img, thumb_b64 = detector_engine.crop_and_enhance(
                image, box["bbox"], box_label=box_label
            )
            box_prompt = (
                LAYOUT_LABEL_TO_PROMPT.get(box_label, prompt_text)
                if prompt_text == "OCR:"
                else prompt_text
            )
            # For LaTeX math formulas, route to base PaddleOCR-VL (which has native LaTeX formula decoding)
            box_use_lora = (
                False
                if box_label in FORMULA_LABELS
                else use_lora
            )
            if box_use_lora and box_label != "text_line" and page_has_khmer is False:
                box_use_lora = False

            start_payload = json.dumps(
                {
                    "type": "region_start",
                    "index": idx,
                    "total": total_boxes,
                    "box": box,
                    "thumb": thumb_b64,
                },
                ensure_ascii=False,
            )
            yield f"data: {start_payload}\n\n"

            try:
                res = self.predict(
                    image=crop_img,
                    prompt_text=box_prompt,
                    max_new_tokens=per_box_max_tokens,
                    use_lora=box_use_lora,
                )
                line_text = res["text"].strip()
                total_tokens += res["tokens"]
                box_elapsed = res["elapsed_ms"]

                # If this is a multi-line layout block (from PP-DocLayoutV2) and the single-line LoRA
                # produced zero Khmer characters, switch to Base PaddleOCR-VL so multi-line English/LaTeX
                # paragraphs are read completely without single-line truncation.
                if box_use_lora and box_label != "text_line":
                    if _contains_khmer(line_text):
                        page_has_khmer = True
                    else:
                        page_has_khmer = False
                        res_base = self.predict(
                            image=crop_img,
                            prompt_text=box_prompt,
                            max_new_tokens=per_box_max_tokens,
                            use_lora=False,
                        )
                        line_text = res_base["text"].strip()
                        total_tokens += res_base["tokens"]
                        box_elapsed = round(box_elapsed + res_base["elapsed_ms"], 1)
            except Exception as exc:
                logger.warning(f"Region #{idx} OCR error: {exc}")
                line_text = ""
                box_elapsed = 0.0

            same_row_as_prev = False
            if idx > 1:
                prev_b = boxes[idx - 2]["bbox"]
                cur_b = box["bbox"]
                prev_cy = (prev_b[1] + prev_b[3]) / 2.0
                cur_cy = (cur_b[1] + cur_b[3]) / 2.0
                prev_bh = max(1, prev_b[3] - prev_b[1])
                cur_bh = max(1, cur_b[3] - cur_b[1])
                if (
                    abs(cur_cy - prev_cy) < max(prev_bh, cur_bh) * 0.55
                    and cur_b[0] >= prev_b[2] - 25
                ):
                    same_row_as_prev = True

            if line_text:
                if same_row_as_prev and recognized_lines:
                    recognized_lines[-1] = f"{recognized_lines[-1]}    {line_text}"
                else:
                    recognized_lines.append(line_text)

            region_item = {
                "id": box["id"],
                "label": box_label,
                "score": box.get("score", 1.0),
                "bbox": box["bbox"],
                "polygon": box["polygon"],
                "text": line_text,
                "same_row_as_prev": same_row_as_prev,
                "elapsed_ms": box_elapsed,
                "thumb": thumb_b64,
            }
            region_results.append(region_item)

            done_box_payload = json.dumps(
                {
                    "type": "region_done",
                    "index": idx,
                    "total": total_boxes,
                    "region": region_item,
                },
                ensure_ascii=False,
            )
            yield f"data: {done_box_payload}\n\n"

        full_text = "\n".join(recognized_lines)
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        tokens_per_sec = (
            round(total_tokens / (elapsed_ms / 1000.0), 1) if elapsed_ms > 0 else 0.0
        )

        done_payload = json.dumps(
            {
                "type": "done",
                "text": full_text,
                "regions": region_results,
                "prompt": prompt_text,
                "use_lora": use_lora,
                "model_id": LORA_MODEL_ID if use_lora else BASE_MODEL_ID,
                "elapsed_ms": elapsed_ms,
                "tokens": total_tokens,
                "tokens_per_sec": tokens_per_sec,
                "image_size": {"width": image.width, "height": image.height},
            },
            ensure_ascii=False,
        )
        yield f"data: {done_payload}\n\n"

    def stream_single_image(
        self,
        image: Image.Image,
        prompt_text: str = "OCR:",
        max_new_tokens: int = 1024,
        use_lora: bool = True,
        boxes: Optional[list[dict]] = None,
    ):
        from transformers import TextIteratorStreamer

        t0 = time.perf_counter()
        inputs = self.prepare_inputs(image, prompt_text)

        tokenizer = getattr(self.processor, "tokenizer", self.processor)
        streamer = TextIteratorStreamer(
            tokenizer,
            skip_prompt=True,
            skip_special_tokens=True,
        )

        generation_error: list[str] = []

        def _generate_worker():
            adapter_ctx = (
                contextlib.nullcontext()
                if use_lora
                else self.model.disable_adapter()
            )
            try:
                with self.lock, adapter_ctx, torch.inference_mode():
                    self.model.generate(
                        **inputs,
                        max_new_tokens=max_new_tokens,
                        do_sample=False,
                        use_cache=True,
                        streamer=streamer,
                    )
            except Exception as exc:
                generation_error.append(str(exc))
                streamer.end()

        thread = threading.Thread(target=_generate_worker, daemon=True)
        thread.start()

        collected_chunks: list[str] = []
        chunk_count = 0

        for token_text in streamer:
            if token_text:
                collected_chunks.append(token_text)
                chunk_count += 1
                payload = json.dumps(
                    {"type": "token", "text": token_text}, ensure_ascii=False
                )
                yield f"data: {payload}\n\n"

        thread.join(timeout=5.0)

        if generation_error:
            err_payload = json.dumps(
                {"type": "error", "error": generation_error[0]}, ensure_ascii=False
            )
            yield f"data: {err_payload}\n\n"
            return

        full_text = self.clean_output_text("".join(collected_chunks), prompt_text)
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        tokens_per_sec = (
            round(chunk_count / (elapsed_ms / 1000.0), 1) if elapsed_ms > 0 else 0.0
        )

        box_item = (
            boxes
            or [
                {
                    "id": 1,
                    "label": "full_image",
                    "score": 1.0,
                    "bbox": [0, 0, image.width, image.height],
                    "polygon": [
                        [0, 0],
                        [image.width, 0],
                        [image.width, image.height],
                        [0, image.height],
                    ],
                }
            ]
        )[0]
        region_item = {
            "id": 1,
            "label": box_item.get("label", "full_image"),
            "score": box_item.get("score", 1.0),
            "bbox": box_item["bbox"],
            "polygon": box_item["polygon"],
            "text": full_text,
            "elapsed_ms": elapsed_ms,
        }
        yield f"data: {json.dumps({'type': 'region_done', 'index': 1, 'total': 1, 'region': region_item}, ensure_ascii=False)}\n\n"

        done_payload = json.dumps(
            {
                "type": "done",
                "text": full_text,
                "regions": [region_item],
                "prompt": prompt_text,
                "use_lora": use_lora,
                "model_id": LORA_MODEL_ID if use_lora else BASE_MODEL_ID,
                "elapsed_ms": elapsed_ms,
                "tokens": chunk_count,
                "tokens_per_sec": tokens_per_sec,
                "image_size": {"width": image.width, "height": image.height},
            },
            ensure_ascii=False,
        )
        yield f"data: {done_payload}\n\n"


model_manager = ModelManager()


@contextlib.asynccontextmanager
async def lifespan(app: FastAPI):
    loader_thread = threading.Thread(target=model_manager.load_model, daemon=True)
    loader_thread.start()
    yield


app = FastAPI(
    title="Khmer PaddleOCR-VL API",
    description="FastAPI service for dvdphobia/Khmer-PaddleOCR-VL-LoRA with Smart Hybrid Detection",
    version="1.3.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


def _read_pil_image(raw_bytes: bytes) -> Image.Image:
    try:
        img = Image.open(io.BytesIO(raw_bytes))
        img = ImageOps.exif_transpose(img)
        return img.convert("RGB")
    except Exception as exc:
        raise HTTPException(status_code=400, detail=f"Invalid image file: {exc}") from exc


def _resolve_prompt(task: str, custom_prompt: Optional[str]) -> str:
    if task == "custom" and custom_prompt and custom_prompt.strip():
        return custom_prompt.strip()
    return TASK_PROMPTS.get(task.lower(), "OCR:")


@app.get("/api/status")
async def get_status():
    return {
        "status": model_manager.status,
        "status_message": model_manager.status_message,
        "error": model_manager.error_detail,
        "device": model_manager.device,
        "device_name": model_manager.get_device_name(),
        "dtype": str(model_manager.dtype).replace("torch.", ""),
        "base_model": BASE_MODEL_ID,
        "lora_model": LORA_MODEL_ID,
        "layout_model": DOCLAYOUT_MODEL_ID,
    }


@app.post("/api/detect")
async def detect_regions(
    file: UploadFile = File(...),
    det_mode: str = Form("smart_hybrid"),
):
    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    try:
        result = await asyncio.to_thread(detector_engine.detect, image, det_mode)
        return JSONResponse(content=result)
    except Exception as exc:
        logger.exception("Text detection error")
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/api/ocr")
async def run_ocr(
    file: UploadFile = File(...),
    task: str = Form("ocr"),
    custom_prompt: Optional[str] = Form(None),
    max_new_tokens: int = Form(1024),
    use_lora: bool = Form(True),
    det_mode: str = Form("smart_hybrid"),
):
    if model_manager.status != "ready":
        raise HTTPException(
            status_code=503,
            detail=f"Model is currently {model_manager.status}: {model_manager.status_message}",
        )

    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    prompt_text = _resolve_prompt(task, custom_prompt)
    max_tokens = max(32, min(int(max_new_tokens), 4096))

    try:
        if det_mode == "none":
            crop_img, _ = detector_engine.crop_and_enhance(
                image, [0, 0, image.width, image.height]
            )
            result = await asyncio.to_thread(
                model_manager.predict,
                image=crop_img,
                prompt_text=prompt_text,
                max_new_tokens=max_tokens,
                use_lora=use_lora,
            )
            return JSONResponse(content=result)

        def _run_region_ocr():
            t0 = time.perf_counter()
            det_res = detector_engine.detect(image, mode=det_mode)
            boxes = det_res["boxes"]
            lines = []
            regions = []
            total_tok = 0
            page_has_khmer: Optional[bool] = None
            for box in boxes:
                box_label = box.get("label", "text_line")
                crop_img, thumb_b64 = detector_engine.crop_and_enhance(
                    image, box["bbox"], box_label=box_label
                )
                box_prompt = (
                    LAYOUT_LABEL_TO_PROMPT.get(box_label, prompt_text)
                    if prompt_text == "OCR:"
                    else prompt_text
                )
                box_use_lora = (
                    False
                    if box_label in FORMULA_LABELS
                    else use_lora
                )
                if box_use_lora and box_label != "text_line" and page_has_khmer is False:
                    box_use_lora = False
                r = model_manager.predict(
                    image=crop_img,
                    prompt_text=box_prompt,
                    max_new_tokens=min(max_tokens, 384),
                    use_lora=box_use_lora,
                )
                txt = r["text"].strip()
                if box_use_lora and box_label != "text_line":
                    if _contains_khmer(txt):
                        page_has_khmer = True
                    else:
                        page_has_khmer = False
                        r = model_manager.predict(
                            image=crop_img,
                            prompt_text=box_prompt,
                            max_new_tokens=min(max_tokens, 384),
                            use_lora=False,
                        )
                        txt = r["text"].strip()
                if txt:
                    lines.append(txt)
                total_tok += r["tokens"]
                regions.append(
                    {
                        "id": box["id"],
                        "label": box_label,
                        "score": box.get("score", 1.0),
                        "bbox": box["bbox"],
                        "polygon": box["polygon"],
                        "text": txt,
                        "elapsed_ms": r["elapsed_ms"],
                        "thumb": thumb_b64,
                    }
                )
            elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
            return {
                "text": "\n".join(lines),
                "regions": regions,
                "prompt": prompt_text,
                "use_lora": use_lora,
                "model_id": LORA_MODEL_ID if use_lora else BASE_MODEL_ID,
                "elapsed_ms": elapsed_ms,
                "tokens": total_tok,
                "tokens_per_sec": (
                    round(total_tok / (elapsed_ms / 1000.0), 1)
                    if elapsed_ms > 0
                    else 0.0
                ),
                "image_size": {"width": image.width, "height": image.height},
            }

        result = await asyncio.to_thread(_run_region_ocr)
        return JSONResponse(content=result)
    except Exception as exc:
        logger.exception("OCR inference error")
        raise HTTPException(status_code=500, detail=str(exc)) from exc


@app.post("/api/ocr/stream")
async def run_ocr_stream(
    file: UploadFile = File(...),
    task: str = Form("ocr"),
    custom_prompt: Optional[str] = Form(None),
    max_new_tokens: int = Form(1024),
    use_lora: bool = Form(True),
    det_mode: str = Form("smart_hybrid"),
):
    if model_manager.status != "ready":
        raise HTTPException(
            status_code=503,
            detail=f"Model is currently {model_manager.status}: {model_manager.status_message}",
        )

    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    prompt_text = _resolve_prompt(task, custom_prompt)
    max_tokens = max(32, min(int(max_new_tokens), 4096))

    return StreamingResponse(
        model_manager.stream_regions_predict(
            image=image,
            prompt_text=prompt_text,
            max_new_tokens=max_tokens,
            use_lora=use_lora,
            det_mode=det_mode,
        ),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            "X-Accel-Buffering": "no",
        },
    )


def _build_docx_bytes(
    text: str,
    regions: list[dict],
    image_size: dict,
    mode: str = "layout",
) -> bytes:
    """
    Generates a standard OpenXML (.docx) file natively using zipfile (zero extra pip deps).
    - mode='plain': exports sequential paragraphs (`លទ្ធផល`).
    - mode='layout': reconstructs the 2D document layout (`ទម្រង់ដូចទំព័រដើម`) with centered titles
      and borderless multi-column Word tables for side-by-side stanzas/cells.
    """
    import zipfile
    from xml.sax.saxutils import escape

    img_w = max(1, int((image_size or {}).get("width") or 1000))
    img_h = max(1, int((image_size or {}).get("height") or 1000))

    def _run_xml(txt_val: str, bold: bool = False, sz_half_pt: int = 24) -> str:
        safe = escape(txt_val or "")
        b_tag = "<w:b/><w:bCs/>" if bold else ""
        return (
            f"<w:r>"
            f"<w:rPr>"
            f'<w:rFonts w:ascii="Kantumruy Pro" w:hAnsi="Kantumruy Pro" w:cs="Khmer OS Siemreap" w:eastAsia="Kantumruy Pro"/>'
            f"{b_tag}<w:sz w:val=\"{sz_half_pt}\"/><w:szCs w:val=\"{sz_half_pt}\"/>"
            f"</w:rPr>"
            f'<w:t xml:space="preserve">{safe}</w:t>'
            f"</w:r>"
        )

    body_parts: list[str] = []

    if mode == "layout" and regions:
        valid_regs = [r for r in regions if (r.get("text") or "").strip() and r.get("bbox")]
        rows = detector_engine._group_into_horizontal_rows(valid_regs)
        for row in rows:
            if len(row) == 1:
                r = row[0]
                x1, y1, x2, y2 = r["bbox"]
                bh = max(1, y2 - y1)
                cx = (x1 + x2) / 2.0
                bw = x2 - x1
                is_centered = (abs(cx - img_w / 2.0) < img_w * 0.14) and (bw < img_w * 0.88) and (x1 > img_w * 0.08)
                is_heading = (bh / float(img_h)) > 0.068 or r.get("label") in {"doc_title", "paragraph_title", "title"}
                jc = "center" if is_centered else "left"
                sz = 32 if is_heading else 22
                lines_in_box = (r.get("text") or "").splitlines() or [""]
                runs = []
                for li, ln in enumerate(lines_in_box):
                    if li > 0:
                        runs.append("<w:r><w:br/></w:r>")
                    runs.append(_run_xml(ln, bold=is_heading, sz_half_pt=sz))
                body_parts.append(
                    f"<w:p><w:pPr><w:jc w:val=\"{jc}\"/><w:spacing w:before=\"40\" w:after=\"60\"/></w:pPr>{''.join(runs)}</w:p>"
                )
            else:
                # Multi-column horizontal row (e.g. Khmer poem stanzas or table row)
                cells_xml = []
                total_w_dxa = 9360
                col_w = max(1000, total_w_dxa // len(row))
                for r in row:
                    lines_in_box = (r.get("text") or "").splitlines() or [""]
                    runs = []
                    for li, ln in enumerate(lines_in_box):
                        if li > 0:
                            runs.append("<w:r><w:br/></w:r>")
                        runs.append(_run_xml(ln, bold=False, sz_half_pt=22))
                    cells_xml.append(
                        f"<w:tc>"
                        f"<w:tcPr><w:tcW w:w=\"{col_w}\" w:type=\"dxa\"/></w:tcPr>"
                        f"<w:p><w:pPr><w:spacing w:before=\"20\" w:after=\"40\"/></w:pPr>{''.join(runs)}</w:p>"
                        f"</w:tc>"
                    )
                body_parts.append(
                    "<w:tbl>"
                    "<w:tblPr>"
                    "<w:tblW w:w=\"9360\" w:type=\"dxa\"/>"
                    "<w:tblBorders>"
                    "<w:top w:val=\"none\"/><w:left w:val=\"none\"/><w:bottom w:val=\"none\"/><w:right w:val=\"none\"/><w:insideH w:val=\"none\"/><w:insideV w:val=\"none\"/>"
                    "</w:tblBorders>"
                    "</w:tblPr>"
                    f"<w:tr>{''.join(cells_xml)}</w:tr>"
                    "</w:tbl>"
                )
    else:
        for ln in (text or "").splitlines():
            body_parts.append(
                f"<w:p><w:pPr><w:spacing w:before=\"20\" w:after=\"60\"/></w:pPr>{_run_xml(ln, bold=False, sz_half_pt=22)}</w:p>"
            )

    document_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<w:document xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/main">'
        f"<w:body>{''.join(body_parts)}"
        '<w:sectPr><w:pgSz w:w="11906" w:h="16838"/><w:pgMar w:top="1080" w:right="1080" w:bottom="1080" w:left="1080"/></w:sectPr>'
        "</w:body></w:document>"
    )

    content_types_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Types xmlns="http://schemas.openxmlformats.org/package/2006/content-types">'
        '<Default Extension="rels" ContentType="application/vnd.openxmlformats-package.relationships+xml"/>'
        '<Default Extension="xml" ContentType="application/xml"/>'
        '<Override PartName="/word/document.xml" ContentType="application/vnd.openxmlformats-officedocument.wordprocessingml.document.main+xml"/>'
        "</Types>"
    )

    rels_xml = (
        '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
        '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/officeDocument" Target="word/document.xml"/>'
        "</Relationships>"
    )

    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", compression=zipfile.ZIP_DEFLATED) as zf:
        zf.writestr("[Content_Types].xml", content_types_xml)
        zf.writestr("_rels/.rels", rels_xml)
        zf.writestr("word/document.xml", document_xml)
    return buf.getvalue()


@app.post("/api/export/docx")
async def export_docx(payload: dict = Body(...)):
    text = payload.get("text") or ""
    regions = payload.get("regions") or []
    image_size = payload.get("image_size") or {"width": 1000, "height": 1000}
    mode = payload.get("mode") or "layout"
    docx_bytes = _build_docx_bytes(text=text, regions=regions, image_size=image_size, mode=mode)
    return Response(
        content=docx_bytes,
        media_type="application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        headers={
            "Content-Disposition": f'attachment; filename="khmer-ocr-{mode}.docx"'
        },
    )


os.makedirs("static", exist_ok=True)
app.mount("/static", StaticFiles(directory="static"), name="static")


@app.get("/")
async def serve_index():
    return FileResponse("static/index.html")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=PORT, reload=False)
