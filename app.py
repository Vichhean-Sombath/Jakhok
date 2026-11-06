import asyncio
import base64
import contextlib
import hashlib
import hmac
import io
import json
import logging
import os
import pathlib
import threading
import time
from collections import OrderedDict
from typing import Optional

from dotenv import load_dotenv

# Load project-local secrets before importing Hugging Face libraries.
PROJECT_ROOT = pathlib.Path(__file__).resolve().parent
load_dotenv(PROJECT_ROOT / ".env", override=False)
API_ONLY = os.environ.get("API_ONLY", "0") == "1"
OCR_ALLOWED_ORIGINS = [
    origin.strip()
    for origin in os.environ.get(
        "OCR_ALLOWED_ORIGINS",
        "http://localhost:8080,http://127.0.0.1:8080,https://neuroshift.dev,https://www.neuroshift.dev",
    ).split(",")
    if origin.strip()
]

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
from checkpoint_sync import (
    DEFAULT_A100_RUN_ID,
    CheckpointOlderThanActiveError,
    load_active_checkpoint,
    resolve_adapter_override,
    sync_latest_checkpoint,
)

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
PRIVATE_RUN_ID = os.environ.get("PRIVATE_RUN_ID", DEFAULT_A100_RUN_ID)
_CHECKPOINTS_ROOT = pathlib.Path(__file__).parent / "checkpoints"


def ensure_latest_private_adapter() -> tuple[str, str]:
    """
    Resolve the activated run/phase/step without mixing adapters from other runs.
    Explicit sync failures are fatal; normal startup uses a validated local marker.
    """
    auto_pull = os.environ.get("AUTO_PULL_LATEST_CHECKPOINT", "0") == "1"
    if auto_pull:
        try:
            manifest = sync_latest_checkpoint(
                repo_id=PRIVATE_CHECKPOINT_REPO,
                run_id=PRIVATE_RUN_ID,
                token=HF_PRIVATE_CHECKPOINT_TOKEN,
                checkpoints_root=_CHECKPOINTS_ROOT,
                base_model_id=BASE_MODEL_ID,
            )
        except CheckpointOlderThanActiveError as exc:
            manifest = load_active_checkpoint(
                checkpoints_root=_CHECKPOINTS_ROOT,
                run_id=PRIVATE_RUN_ID,
                repo_id=PRIVATE_CHECKPOINT_REPO,
                base_model_id=BASE_MODEL_ID,
            )
            if manifest is None or int(manifest["optimizer_step"]) <= exc.incoming_step:
                raise RuntimeError(
                    f"HF checkpoint is older than step {exc.active_step}, but no valid newer active "
                    "checkpoint is available."
                ) from None
            logger.warning(
                "HF latest is step %s; keeping validated active step %s from %s and starting with it.",
                exc.incoming_step, manifest["optimizer_step"],
                manifest.get("source_identity") or manifest.get("repo_revision"),
            )
        except Exception as exc:
            raise RuntimeError(
                f"Explicit checkpoint sync failed for run {PRIVATE_RUN_ID!r}: {exc}. "
                "No other run was selected."
            ) from None
    else:
        manifest = load_active_checkpoint(
            checkpoints_root=_CHECKPOINTS_ROOT,
            run_id=PRIVATE_RUN_ID,
            repo_id=PRIVATE_CHECKPOINT_REPO,
            base_model_id=BASE_MODEL_ID,
        )
    if manifest is not None:
        adapter_path = _CHECKPOINTS_ROOT / manifest["adapter_path"]
        parent_note = (
            f", parent {manifest['parent_run_id']} step {manifest['parent_optimizer_step']:,}"
            if manifest.get("parent_run_id") is not None else ""
        )
        display = (
            f"OpenKhmer {manifest.get('training_phase') or 'checkpoint'} step "
            f"{manifest['optimizer_step']:,}{parent_note} EMA LoRA"
        )
        if manifest.get("source_type", "hf") == "hf":
            logger.info(
                "Using activated OpenKhmer run %s step %s from pinned HF revision %s%s",
                manifest["run_id"], manifest["optimizer_step"], manifest["repo_revision"], parent_note,
            )
        else:
            logger.info(
                "Using activated OpenKhmer run %s step %s from %s%s",
                manifest["run_id"], manifest["optimizer_step"],
                manifest["source_identity"], parent_note,
            )
        return str(adapter_path), display

    raise RuntimeError(
        f"No active checkpoint marker exists for configured run {PRIVATE_RUN_ID!r}. "
        "Run `python sync_checkpoint.py` to fetch and activate that run, or set LORA_MODEL_ID explicitly."
    )


def _resolve_default_adapter():
    return ensure_latest_private_adapter()


_RESOLVED_ADAPTER_PATH, _RESOLVED_DISPLAY_NAME = resolve_adapter_override(
    os.environ.get("LORA_MODEL_ID"), _resolve_default_adapter,
)
LORA_MODEL_ID = _RESOLVED_ADAPTER_PATH
LORA_DISPLAY_NAME = _RESOLVED_DISPLAY_NAME
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
    "table": "Table Recognition:",
    "chart": "Chart Recognition:",
}

FORMULA_LABELS = {"formula", "display_formula", "inline_formula"}
# PP-DocLayoutV2 label set: running heads, feet and page numbers are not body text.
LAYOUT_SKIP_LABELS = {"header", "footer", "number"}
BASE_REGION_PROMPTS = {
    LAYOUT_LABEL_TO_PROMPT[name]
    for name in (FORMULA_LABELS | {"table", "chart"})
    if name in LAYOUT_LABEL_TO_PROMPT
}
TASK_REGION_LABELS = {
    "table": {"table"},
    "formula": FORMULA_LABELS,
    "chart": {"chart"},
}
# Block-level labels that the Khmer single-line LoRA cannot recognize well and
# that need the base model's native table/chart/formula decoding.
LAYOUT_BASE_LABELS = FORMULA_LABELS | {"table", "chart"}

VALID_DET_MODES = {"smart_hybrid", "pp_doclayout_v2", "standard", "dense", "none"}

# Controlled pre-scaling for DBNet. RapidOCR applies its max-side reduction
# before its min-side floor, so a tall strip could otherwise be upscaled to
# tens of megapixels. We pre-scale once and run the detector in "max" mode.
DET_SCALE_TARGETS = {
    "standard": {"floor": 1280, "cap": 2000, "max_pixels": 4_000_000},
    "dense": {"floor": 1600, "cap": 2560, "max_pixels": 6_000_000},
}


def _contains_khmer(text: str) -> bool:
    return any("\u1780" <= ch <= "\u17ff" for ch in text)


def _box_iou(b1: list[int], b2: list[int]) -> float:
    """Standard Intersection over Union (IoU), not intersection over smaller area."""
    x1 = max(b1[0], b2[0])
    y1 = max(b1[1], b2[1])
    x2 = min(b1[2], b2[2])
    y2 = min(b1[3], b2[3])
    inter = max(0, x2 - x1) * max(0, y2 - y1)
    if inter <= 0:
        return 0.0
    a1 = max(1, (b1[2] - b1[0]) * (b1[3] - b1[1]))
    a2 = max(1, (b2[2] - b2[0]) * (b2[3] - b2[1]))
    union = a1 + a2 - inter
    if union <= 0:
        return 0.0
    return inter / float(union)


def _box_area(box: list[int]) -> int:
    return max(1, (box[2] - box[0]) * (box[3] - box[1]))


def _box_intersection(b1: list[int], b2: list[int]) -> int:
    x1 = max(b1[0], b2[0])
    y1 = max(b1[1], b2[1])
    x2 = min(b1[2], b2[2])
    y2 = min(b1[3], b2[3])
    return max(0, x2 - x1) * max(0, y2 - y1)


def _box_containment(b1: list[int], b2: list[int]) -> float:
    """Intersection over the smaller box's area (1.0 means fully contained)."""
    inter = _box_intersection(b1, b2)
    if inter <= 0:
        return 0.0
    return inter / float(min(_box_area(b1), _box_area(b2)))


def _box_center(box: list[int]) -> tuple[float, float]:
    return ((box[0] + box[2]) / 2.0, (box[1] + box[3]) / 2.0)


def _compute_det_scale(
    width: int, height: int, floor: int, cap: int, max_pixels: int
) -> float:
    """Choose one bounded scale for a DBNet pass.

    The min-side floor is only applied while it fits the long-side cap and the
    pixel budget, so an extreme-aspect strip is never inflated to tens of MP.
    """
    if width <= 0 or height <= 0:
        return 1.0
    short_side = min(width, height)
    long_side = max(width, height)
    scale = 1.0
    if short_side < floor:
        scale = floor / float(short_side)
    scale = min(scale, cap / float(long_side))
    if width * height * scale * scale > max_pixels:
        scale = (max_pixels / float(width * height)) ** 0.5
    return max(scale, 0.02)


def _full_image_box(width: int, height: int) -> dict:
    return {
        "id": 1,
        "label": "full_image",
        "score": 1.0,
        "bbox": [0, 0, width, height],
        "polygon": [[0, 0], [width, 0], [width, height], [0, height]],
    }


def _filter_boxes_for_task(
    boxes: list[dict], task: str, image: Image.Image
) -> list[dict]:
    """Select the regions that make sense for a block-level task.

    Table/Formula/Chart recognition should run on the matching layout block,
    not on every DBNet text line. If no matching block exists, fall back to
    the whole image so the task still receives a valid crop.
    """
    allowed = TASK_REGION_LABELS.get((task or "").lower())
    if allowed is None:
        return boxes
    selected = [box for box in boxes if box.get("label") in allowed]
    if selected:
        return selected
    width, height = image.size
    return [_full_image_box(width, height)]


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
        # Both engines are part of the published state; checking only the
        # standard engine could expose a half-initialized dense engine.
        if self._det_standard is not None and self._det_dense is not None:
            return
        with self._lock:
            if self._det_standard is not None and self._det_dense is not None:
                return
            from rapidocr_onnxruntime import RapidOCR

            # RapidOCR's UpdateParameters strips only the leading "det_" from
            # constructor kwargs, so detector keys must keep that prefix
            # (bare thresh/box_thresh land in Global and are ignored).
            # The app pre-scales each page in _detect_dbnet. Running the inner
            # detector with limit_type="max" prevents RapidOCR's uncapped
            # min-side upscale (the global max_side_len was applied first, so
            # it was never an outer cap for tall strips).
            # max_side_len is a Global key, hence intentionally unprefixed.
            standard = RapidOCR(
                max_side_len=2000,
                det_limit_side_len=2000,
                det_limit_type="max",
                det_thresh=0.24,
                det_box_thresh=0.38,
                det_unclip_ratio=1.32,
                det_use_dilation=False,
            )
            # Dense uses a real 1600 px min floor. _detect_dbnet only selects
            # it when its pre-scaled image already has a >=1600 px short side,
            # so this floor can never inflate an extreme-aspect strip.
            dense = RapidOCR(
                max_side_len=2560,
                det_limit_side_len=1600,
                det_limit_type="min",
                det_thresh=0.20,
                det_box_thresh=0.32,
                det_unclip_ratio=1.28,
                det_use_dilation=False,
            )
            # Publish only after both constructors succeed.
            self._det_standard = standard
            self._det_dense = dense

    @staticmethod
    def _group_into_horizontal_rows(boxes: list[dict]) -> list[list[dict]]:
        """Group boxes into rows using a stable median-height tolerance.

        The previous running mean let one tall box raise the tolerance for
        every later box and merge distinct lines. Rows are assigned to the
        nearest representative center within a fixed tolerance instead.
        """
        if not boxes:
            return []
        heights = sorted(max(1, b["bbox"][3] - b["bbox"][1]) for b in boxes)
        median_h = heights[len(heights) // 2]
        tolerance = max(6.0, median_h * 0.55)

        ordered = sorted(
            boxes,
            key=lambda b: ((b["bbox"][1] + b["bbox"][3]) / 2.0, b["bbox"][0]),
        )
        rows: list[list[dict]] = []
        for b in ordered:
            cy = (b["bbox"][1] + b["bbox"][3]) / 2.0
            best_row = None
            best_delta = tolerance
            for row in rows:
                row_cy = sum(
                    (r["bbox"][1] + r["bbox"][3]) / 2.0 for r in row
                ) / len(row)
                delta = abs(cy - row_cy)
                if delta <= best_delta:
                    best_row = row
                    best_delta = delta
            if best_row is None:
                rows.append([b])
            else:
                best_row.append(b)

        rows.sort(
            key=lambda row: sum((r["bbox"][1] + r["bbox"][3]) / 2.0 for r in row)
            / len(row)
        )
        for row in rows:
            row.sort(key=lambda b: b["bbox"][0])
        return rows

    @staticmethod
    def _find_recurring_gap_columns(
        rows: list[list[dict]], image_width: int
    ) -> list[int]:
        """Find x positions where a gap between boxes repeats across rows.

        These are table-column boundaries or page gutters. Merging across
        them is what turns cells into page-wide boxes.
        """
        row_count = sum(1 for row in rows if len(row) >= 2)
        if row_count < 2:
            return []
        counts: dict[int, int] = {}
        for row in rows:
            seen: set[int] = set()
            for prev, cur in zip(row, row[1:]):
                gap = cur["bbox"][0] - prev["bbox"][2]
                # Only real whitespace can be a column/gutter. Touching or
                # overlapping same-line fragments must stay mergeable.
                if gap < 1:
                    continue
                center = (prev["bbox"][2] + cur["bbox"][0]) / 2.0
                if not (image_width * 0.02 <= center <= image_width * 0.98):
                    continue
                bucket = int(round(center / 12.0)) * 12
                if bucket not in seen:
                    seen.add(bucket)
                    counts[bucket] = counts.get(bucket, 0) + 1
        threshold = max(2, int(round(row_count * 0.30)))
        return sorted(bucket for bucket, count in counts.items() if count >= threshold)

    @staticmethod
    def _gap_has_vertical_rule(
        gray: Optional[np.ndarray],
        x1: int,
        x2: int,
        y1: int,
        y2: int,
    ) -> bool:
        """True when a near-vertical dark rule spans most of the gap band."""
        if gray is None or x2 - x1 < 1:
            return False
        height, width = gray.shape[:2]
        bx1 = max(0, min(width, int(x1)))
        bx2 = max(0, min(width, int(x2)))
        by1 = max(0, min(height, int(y1)))
        by2 = max(0, min(height, int(y2)))
        if bx2 - bx1 < 1 or by2 - by1 < 4:
            return False
        band = gray[by1:by2, bx1:bx2]
        if band.size == 0:
            return False
        dark_fraction = (band < 180).mean(axis=0)
        return bool((dark_fraction >= 0.70).any())

    @classmethod
    def _merge_horizontal_line_fragments(
        cls,
        boxes: list[dict],
        image_width: int,
        gray: Optional[np.ndarray] = None,
    ) -> list[dict]:
        """Merge same-line fragments without crossing gutters or table rules.

        The old rule classified any short box as punctuation and allowed a
        1.85x line-height gap, which merged adjacent table cells into
        page-wide boxes. A gap may now bridge at most 0.55x the line height,
        and never a gap position that repeats across rows or contains a
        vertical rule.
        """
        if len(boxes) <= 1:
            return boxes

        rows = cls._group_into_horizontal_rows(boxes)
        separators = cls._find_recurring_gap_columns(rows, image_width)
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
                min_h = min(ph, bh)

                y_overlap = min(py2, by2) - max(py1, by1)
                center_delta = abs((py1 + py2) / 2.0 - (by1 + by2) / 2.0)
                same_line = (
                    y_overlap > 0.45 * min_h and center_delta <= 0.30 * min_h
                )
                horiz_gap = bx1 - px2
                max_gap = 0.55 * max(ph, bh)
                min_gap = -0.30 * min(pw, bw)

                gap_lo = min(px2, bx1) - 2
                gap_hi = max(px2, bx1) + 2
                crosses_separator = any(
                    gap_lo <= separator <= gap_hi for separator in separators
                )
                # Check the whole interval between the nearest edges, not
                # just a positive gap: DB can hand back overlapping boxes
                # that still straddle a cell border.
                crosses_rule = cls._gap_has_vertical_rule(
                    gray,
                    min(px2, bx1),
                    max(px2, bx1),
                    min(py1, by1),
                    max(py2, by2),
                )

                if (
                    same_line
                    and not crosses_separator
                    and not crosses_rule
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

    @staticmethod
    def _contiguous_edge_run(
        valid: np.ndarray, edge_index: int, step: int, edge_gap: int, max_run: int
    ) -> Optional[tuple[int, int]]:
        """Find an ink run starting near the box edge and walking outward.

        Returns (near_offset, far_offset) measured in columns away from the
        edge, or None when the first ink is too far, the run is a long rule,
        or the run is not contiguous (at most a 1 px gap).
        """
        first = None
        for offset in range(0, edge_gap + 1):
            idx = edge_index + step * offset
            if 0 <= idx < len(valid) and valid[idx]:
                first = offset
                break
        if first is None:
            return None

        last = first
        gap = 0
        for offset in range(first + 1, len(valid)):
            idx = edge_index + step * offset
            if not (0 <= idx < len(valid)):
                break
            if valid[idx]:
                last = offset
                gap = 0
            else:
                gap += 1
                if gap > 1:
                    break
        if last - first + 1 > max_run:
            return None
        return first, last

    @classmethod
    def _expand_line_punctuation_margins(
        cls,
        boxes: list[dict],
        image: Image.Image,
        gray: Optional[np.ndarray] = None,
    ) -> list[dict]:
        """Include a nearby isolated bullet or Khmer punctuation mark.

        Expansion is limited to contiguous ink within 0.25x line height of
        the box edge and at most 0.45x line height wide. This rejects long
        rules, underlines and form lines, which previously pulled boxes out
        by up to 46/56 px.
        """
        if not boxes:
            return boxes
        import cv2

        w, h = image.size
        if gray is None:
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

                edge_gap = max(3, int(round(bh * 0.25)))
                max_run = max(4, int(round(bh * 0.45)))
                max_growth = max(6, int(round(bh * 0.50)))
                search = edge_gap + max_run + 4

                left_limit = (
                    max(0, bx1 - search)
                    if i == 0
                    else max(row[i - 1]["bbox"][2] + 3, bx1 - search)
                )
                right_limit = (
                    min(w, bx2 + search)
                    if i == len(row) - 1
                    else min(row[i + 1]["bbox"][0] - 3, bx2 + search)
                )

                if left_limit < bx1:
                    l_band = gray[y_top:y_bot, left_limit:bx1]
                    dark_cols = (l_band < 200).sum(axis=0)
                    valid = (dark_cols >= 2) & (
                        dark_cols <= max(3, int(band_h * 0.70))
                    )
                    run = cls._contiguous_edge_run(
                        valid, len(valid) - 1, -1, edge_gap, max_run
                    )
                    if run is not None:
                        far = run[1]
                        new_x1 = max(
                            left_limit, bx1 - far - 3, bx1 - max_growth
                        )
                        bx1 = max(0, int(new_x1))

                if right_limit > bx2:
                    r_band = gray[y_top:y_bot, bx2:right_limit]
                    dark_cols = (r_band < 200).sum(axis=0)
                    valid = (dark_cols >= 2) & (
                        dark_cols <= max(3, int(band_h * 0.70))
                    )
                    run = cls._contiguous_edge_run(valid, 0, 1, edge_gap, max_run)
                    if run is not None:
                        far = run[1]
                        new_x2 = min(
                            right_limit, bx2 + far + 4, bx2 + max_growth
                        )
                        bx2 = min(w, int(new_x2))

                b["bbox"] = [bx1, by1, bx2, by2]
                b["polygon"] = [
                    [bx1, by1],
                    [bx2, by1],
                    [bx2, by2],
                    [bx1, by2],
                ]
                out.append(b)

        return out

    @staticmethod
    def _deoverlap_vertical_boxes(
        boxes: list[dict], labels: Optional[set[str]] = None
    ) -> list[dict]:
        """Clip sliver overlaps between adjacent text-line boxes.

        Display boxes should not paint over each other. Crops keep their own
        padded `crop_bbox`, so clipping the display bbox does not remove
        Khmer ascenders or vowel signs from recognition.
        """
        if labels is None:
            labels = {"text_line"}
        candidates = [
            b
            for b in boxes
            if b.get("label") in labels
            and "bbox" in b
            and (b["bbox"][2] > b["bbox"][0])
            and (b["bbox"][3] > b["bbox"][1])
        ]
        for i, first in enumerate(candidates):
            for second in candidates[i + 1 :]:
                a = first["bbox"]
                c = second["bbox"]
                width_overlap = min(a[2], c[2]) - max(a[0], c[0])
                if width_overlap < 0.35 * min(a[2] - a[0], c[2] - c[0]):
                    continue
                vertical_overlap = min(a[3], c[3]) - max(a[1], c[1])
                if vertical_overlap <= 0:
                    continue
                ah = max(1, a[3] - a[1])
                ch = max(1, c[3] - c[1])
                # Only trim sliver overlaps. Large overlaps are duplicates and
                # are handled by layout NMS; paragraph blocks are left alone.
                if vertical_overlap > 0.85 * min(ah, ch):
                    continue
                if max(ah, ch) > 2.5 * min(ah, ch):
                    continue
                ac = (a[1] + a[3]) / 2.0
                cc = (c[1] + c[3]) / 2.0
                # Same-line fragments are merged elsewhere; never split them
                # by treating their small center offset as a line boundary.
                if abs(ac - cc) <= 0.30 * min(ah, ch):
                    continue
                mid = int(round((ac + cc) / 2.0))
                if ac < cc:
                    if mid - a[1] >= 4:
                        a[3] = min(a[3], mid)
                    if c[3] - mid >= 4:
                        c[1] = max(c[1], mid)
                else:
                    if mid - c[1] >= 4:
                        c[3] = min(c[3], mid)
                    if a[3] - mid >= 4:
                        a[1] = max(a[1], mid)
                first["polygon"] = [
                    [a[0], a[1]],
                    [a[2], a[1]],
                    [a[2], a[3]],
                    [a[0], a[3]],
                ]
                second["polygon"] = [
                    [c[0], c[1]],
                    [c[2], c[1]],
                    [c[2], c[3]],
                    [c[0], c[3]],
                ]
        return boxes

    @classmethod
    def _sort_boxes_reading_order(
        cls,
        boxes: list[dict],
        image_width: int = 1000,
        allow_two_column: bool = False,
        column_split: Optional[float] = None,
    ) -> list[dict]:
        if not boxes:
            return []

        # Identity-based dedupe. The old column predicate could put the same
        # centered dict in both column lists and emit it twice.
        unique: list[dict] = []
        seen_ids: set[int] = set()
        for box in boxes:
            if id(box) in seen_ids:
                continue
            seen_ids.add(id(box))
            unique.append(box)
        boxes = unique

        def _sort_single_column(col_boxes: list[dict]) -> list[dict]:
            rows = cls._group_into_horizontal_rows(col_boxes)
            return [b for row in rows for b in row]

        use_columns = allow_two_column or column_split is not None
        if use_columns:
            split_x = (
                float(column_split)
                if column_split is not None
                else image_width / 2.0
            )
            margin = image_width * 0.04
            spanning = [
                b
                for b in boxes
                if b["bbox"][0] < split_x - margin
                and b["bbox"][2] > split_x + margin
            ]
            spanning_ids = {id(b) for b in spanning}
            non_spanning = [b for b in boxes if id(b) not in spanning_ids]
            left_col = [
                b
                for b in non_spanning
                if (b["bbox"][0] + b["bbox"][2]) / 2.0 < split_x
            ]
            right_col = [
                b
                for b in non_spanning
                if (b["bbox"][0] + b["bbox"][2]) / 2.0 >= split_x
            ]
            if (
                len(left_col) >= 4
                and len(right_col) >= 4
                and len(spanning) <= max(3, int(0.2 * len(boxes)))
            ):
                left_seq = _sort_single_column(left_col)
                right_seq = _sort_single_column(right_col)
                spanning_seq = _sort_single_column(spanning)
                ordered = []
                li = ri = 0
                for span in spanning_seq:
                    span_y = (span["bbox"][1] + span["bbox"][3]) / 2.0
                    while (
                        li < len(left_seq)
                        and (left_seq[li]["bbox"][1] + left_seq[li]["bbox"][3]) / 2.0
                        < span_y
                    ):
                        ordered.append(left_seq[li])
                        li += 1
                    while (
                        ri < len(right_seq)
                        and (right_seq[ri]["bbox"][1] + right_seq[ri]["bbox"][3]) / 2.0
                        < span_y
                    ):
                        ordered.append(right_seq[ri])
                        ri += 1
                    ordered.append(span)
                ordered.extend(left_seq[li:])
                ordered.extend(right_seq[ri:])
            else:
                ordered = _sort_single_column(boxes)
        else:
            ordered = _sort_single_column(boxes)

        ordered_unique: list[dict] = []
        emitted: set[int] = set()
        for item in ordered:
            if id(item) in emitted:
                continue
            emitted.add(id(item))
            ordered_unique.append(item)

        for idx, item in enumerate(ordered_unique):
            item["id"] = idx + 1
        return ordered_unique

    @staticmethod
    def _has_table_rules(
        gray: Optional[np.ndarray], min_runs: int = 3
    ) -> bool:
        """Detect repeated full-width horizontal rules (tables/forms)."""
        if gray is None:
            return False
        height, width = gray.shape[:2]
        if height < 10 or width < 10:
            return False
        dark_fraction = (gray < 160).mean(axis=1)
        runs = 0
        in_run = False
        for fraction in dark_fraction:
            if fraction >= 0.85:
                if not in_run:
                    runs += 1
                    in_run = True
            else:
                in_run = False
        return runs >= min_runs

    @staticmethod
    def _detect_two_column_split(
        boxes: list[dict],
        image_width: int,
        gray: Optional[np.ndarray] = None,
    ) -> Optional[float]:
        """Return a stable central gutter x, or None when the page is not a
        two-column text layout.

        Candidates come from gaps that recur across rows, so a full-width
        title cannot hide the gutter. Forms/tables are rejected by horizontal
        rules, width similarity and the multi-gutter check.
        """
        if len(boxes) < 8 or image_width <= 0:
            return None
        if TextDetectorEngine._has_table_rules(gray):
            return None

        rows = TextDetectorEngine._group_into_horizontal_rows(boxes)
        separators = TextDetectorEngine._find_recurring_gap_columns(
            rows, image_width
        )
        # A wobbling gutter can land in two adjacent 12 px buckets. Cluster
        # nearby separators before the multi-gutter (3+ column) check.
        clusters: list[list[int]] = []
        for center in sorted(separators):
            if clusters and center - clusters[-1][-1] <= 24:
                clusters[-1].append(center)
            else:
                clusters.append([center])
        candidates = [
            sum(cluster) / len(cluster)
            for cluster in clusters
            if image_width * 0.25
            <= sum(cluster) / len(cluster)
            <= image_width * 0.75
        ]
        if not candidates:
            return None

        def gap_width(center: float) -> int:
            left_edges = [
                b["bbox"][2] for b in boxes if b["bbox"][2] <= center + 6
            ]
            right_edges = [
                b["bbox"][0] for b in boxes if b["bbox"][0] >= center - 6
            ]
            if not left_edges or not right_edges:
                return 0
            return max(0, int(min(right_edges) - max(left_edges)))

        widths = {center: gap_width(center) for center in candidates}
        widest = max(widths.values())
        if sum(1 for width in widths.values() if width >= 0.60 * widest) > 1:
            # More than one equally wide gutter: a 3+ column grid or table.
            return None

        for center in sorted(candidates, key=lambda c: -widths[c]):
            margin = max(8, int(round(image_width * 0.01)))
            crossing = [
                b
                for b in boxes
                if b["bbox"][0] < center - margin
                and b["bbox"][2] > center + margin
            ]
            crossing_ids = {id(b) for b in crossing}
            non_spanning = [b for b in boxes if id(b) not in crossing_ids]
            left = [
                b
                for b in non_spanning
                if (b["bbox"][0] + b["bbox"][2]) / 2.0 < center
            ]
            right = [
                b
                for b in non_spanning
                if (b["bbox"][0] + b["bbox"][2]) / 2.0 >= center
            ]
            if (
                len(left) < 6
                or len(right) < 6
                or len(crossing) > max(2, int(0.15 * len(boxes)))
            ):
                continue
            left_widths = sorted(b["bbox"][2] - b["bbox"][0] for b in left)
            right_widths = sorted(b["bbox"][2] - b["bbox"][0] for b in right)
            left_median = left_widths[len(left_widths) // 2]
            right_median = right_widths[len(right_widths) // 2]
            narrower = min(left_median, right_median)
            wider = max(left_median, right_median)
            if narrower < image_width * 0.08:
                continue
            if narrower < 0.60 * wider:
                # Label/value form or asymmetric grid, not two text columns.
                continue
            return center
        return None

    @staticmethod
    def _nms_layout(candidates: list[dict]) -> list[dict]:
        """Per-label NMS with containment suppression.

        Standard IoU alone cannot remove a large text block that contains
        many line boxes (containment 1.0, IoU ~0.05). Same-label containment
        is therefore treated as duplication as well.
        """
        ordered = sorted(
            candidates,
            key=lambda c: (-c["score"], _box_area(c["bbox"])),
        )
        kept: list[dict] = []
        for cand in ordered:
            duplicate = False
            for existing in kept:
                if cand["label"] != existing["label"]:
                    continue
                if (
                    _box_iou(cand["bbox"], existing["bbox"]) > 0.55
                    or _box_containment(cand["bbox"], existing["bbox"]) > 0.85
                ):
                    duplicate = True
                    break
            if not duplicate:
                kept.append(cand)
        return kept

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
                # Move and retry under the same lock as inference so another
                # request cannot use a half-moved model or stale MPS inputs.
                with self._lock, torch.inference_mode():
                    if self._doclayout_device == "mps":
                        self._doclayout_device = "cpu"
                        self._doclayout_model = self._doclayout_model.to("cpu")
                    dev_inputs = {
                        k: v.to(self._doclayout_device)
                        if isinstance(v, torch.Tensor)
                        else v
                        for k, v in inputs.items()
                    }
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

            if label_name in LAYOUT_SKIP_LABELS:
                continue

            x1, y1, x2, y2 = [float(v) for v in box_t.tolist()]
            bx1 = max(0, int(round(x1)))
            by1 = max(0, int(round(y1)))
            bx2 = min(w, int(round(x2)))
            by2 = min(h, int(round(y2)))

            if (bx2 - bx1) < 10 or (by2 - by1) < 10:
                continue

            candidates.append(
                {
                    "id": 0,
                    "label": label_name,
                    "score": round(score, 3),
                    "bbox": [bx1, by1, bx2, by2],
                    # Crops keep 2 px of context; display geometry stays tight
                    # so adjacent blocks do not overlap from padding.
                    "crop_bbox": [
                        max(0, bx1 - 2),
                        max(0, by1 - 2),
                        min(w, bx2 + 2),
                        min(h, by2 + 2),
                    ],
                    "polygon": [
                        [bx1, by1],
                        [bx2, by1],
                        [bx2, by2],
                        [bx1, by2],
                    ],
                }
            )

        kept = self._nms_layout(candidates)
        kept = self._suppress_text_inside_blocks(kept)
        # The model can emit line boxes that share a few pixels; trim the
        # display sliver while the crop_bbox keeps the context.
        kept = self._deoverlap_vertical_boxes(kept, labels={"text", "content"})
        return self._sort_boxes_reading_order(
            kept, image_width=w, allow_two_column=True
        )

    @staticmethod
    def _suppress_text_inside_blocks(boxes: list[dict]) -> list[dict]:
        """Drop text blocks fully contained in a table/chart block.

        Same-label NMS cannot remove these because the labels differ; without
        this, the Layout tab paints table text and table-cell lines on top of
        each other.
        """
        containers = [
            b for b in boxes if b["label"] in {"table", "chart"}
        ]
        if not containers:
            return boxes
        return [
            b
            for b in boxes
            if not (
                b["label"] in {"text", "content"}
                and any(
                    _box_containment(b["bbox"], c["bbox"]) > 0.85
                    and _box_area(c["bbox"]) > _box_area(b["bbox"])
                    for c in containers
                )
            )
        ]

    def _detect_dbnet(
        self, image: Image.Image, mode: str = "standard", merge_fragments: bool = False
    ) -> list[dict]:
        self._ensure_dbnet_initialized()
        w, h = image.size

        border_pad = 12
        padded_img = ImageOps.expand(image, border=border_pad, fill=(255, 255, 255))
        pw, ph = padded_img.size

        target = DET_SCALE_TARGETS["dense" if mode == "dense" else "standard"]
        scale = _compute_det_scale(
            pw,
            ph,
            target["floor"],
            target["cap"],
            target["max_pixels"],
        )
        work_img = padded_img
        if abs(scale - 1.0) > 1e-3:
            work_img = padded_img.resize(
                (max(1, int(round(pw * scale))), max(1, int(round(ph * scale)))),
                Image.Resampling.LANCZOS,
            )

        img_np = np.array(work_img)
        detector = self._det_standard
        if mode == "dense" and min(work_img.size) >= 1600:
            # Dense's min-side floor is only safe when pre-scaling already
            # reached it; otherwise the floor would upscale a strip without
            # bound. Fall back to the bounded standard detector.
            detector = self._det_dense

        with self._lock:
            raw_boxes, _ = detector(img_np, use_det=True, use_cls=False, use_rec=False)

        parsed_boxes: list[dict] = []

        def _crop_box(raw_box: list[int]) -> list[int]:
            box_h = max(1, raw_box[3] - raw_box[1])
            cx = max(2, int(round(box_h * 0.04)))
            cy = max(3, int(round(box_h * 0.08)))
            return [
                max(0, raw_box[0] - cx),
                max(0, raw_box[1] - cy),
                min(w, raw_box[2] + cx),
                min(h, raw_box[3] + cy),
            ]

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

                # Display geometry stays tight. The padded box is kept
                # separately for recognition so Khmer ascenders and vowel
                # signs are not clipped and widening the display box is not
                # needed to protect the crop.
                bx1 = max(0, int(round(x1)))
                by1 = max(0, int(round(y1)))
                bx2 = min(w, int(round(x2)))
                by2 = min(h, int(round(y2)))
                if bx2 - bx1 < 5 or by2 - by1 < 5:
                    continue

                parsed_boxes.append(
                    {
                        "id": 0,
                        "label": "text_line",
                        "score": 1.0,
                        "bbox": [bx1, by1, bx2, by2],
                        "crop_bbox": _crop_box([bx1, by1, bx2, by2]),
                        "polygon": [[round(p[0], 1), round(p[1], 1)] for p in pts],
                    }
                )

        # One grayscale copy shared by the merge rule check, the
        # punctuation-band scan, and the table/form guard for column detection.
        gray = np.array(image.convert("L"))
        if merge_fragments:
            parsed_boxes = self._merge_horizontal_line_fragments(
                parsed_boxes, w, gray=gray
            )
            parsed_boxes = self._expand_line_punctuation_margins(
                parsed_boxes, image, gray=gray
            )

        # Merge/expansion change the display bbox; refresh the recognition
        # crop from the final geometry, then trim display slivers only.
        for item in parsed_boxes:
            item["crop_bbox"] = _crop_box(item["bbox"])
        parsed_boxes = self._deoverlap_vertical_boxes(parsed_boxes)

        split = self._detect_two_column_split(parsed_boxes, w, gray=gray)
        return self._sort_boxes_reading_order(
            parsed_boxes, image_width=w, column_split=split
        )

    def detect(
        self,
        image: Image.Image,
        mode: str = "smart_hybrid",
        task: str = "ocr",
    ) -> dict:
        t0 = time.perf_counter()
        w, h = image.size
        task_lower = (task or "ocr").lower()

        if mode == "none":
            return {
                "mode": "none",
                "elapsed_ms": 0.1,
                "image_size": {"width": w, "height": h},
                "boxes": [_full_image_box(w, h)],
            }

        ordered_boxes: list[dict] = []

        if mode == "smart_hybrid":
            # Text is always recognized from DBNet line boxes because the
            # Khmer LoRA is trained on single-line crops. Layout blocks are
            # used only where a block-level prompt is correct: formulas,
            # tables and charts. This removes the old "one formula flips the
            # whole page to paragraph crops" failure.
            layout_boxes = self._detect_pp_doclayout_v2(image, threshold=0.42)
            dbnet_boxes = self._detect_dbnet(
                image, mode="standard", merge_fragments=True
            )
            # Formulas are safe to add to an OCR page. Table/chart blocks are
            # only included when that task is selected: the layout model can
            # mislabel a text-heavy page as one full-page table, which would
            # otherwise replace every line region with a table crop.
            block_labels = set(FORMULA_LABELS)
            if task_lower in {"table", "chart"}:
                block_labels.add(task_lower)
            block_boxes = [
                b for b in layout_boxes if b["label"] in block_labels
            ]

            if block_boxes:
                def _center_in_block(box: dict, block: dict) -> bool:
                    cx, cy = _box_center(box["bbox"])
                    bb = block["bbox"]
                    return bb[0] <= cx <= bb[2] and bb[1] <= cy <= bb[3]

                def _line_is_block_content(box: dict, block: dict) -> bool:
                    # Table/chart blocks own everything whose center falls
                    # inside them. A formula only replaces a line when the
                    # line is genuinely the formula crop; an inline formula
                    # must not delete the surrounding text line.
                    if block["label"] in FORMULA_LABELS:
                        # Fraction of the LINE covered by the formula block.
                        # Containment over the smaller area would also be 1.0
                        # for a small inline formula.
                        return (
                            _box_intersection(box["bbox"], block["bbox"])
                            / float(_box_area(box["bbox"]))
                        ) > 0.75
                    return _center_in_block(box, block)

                text_boxes = [
                    b
                    for b in dbnet_boxes
                    if not any(
                        _line_is_block_content(b, block) for block in block_boxes
                    )
                ]
                blocks_to_add: list[dict] = []
                for block in block_boxes:
                    if block["label"] in FORMULA_LABELS and any(
                        _box_containment(block["bbox"], line["bbox"]) > 0.85
                        and _box_area(line["bbox"]) > 1.5 * _box_area(block["bbox"])
                        for line in text_boxes
                    ):
                        # Inline formula: the line crop already contains it.
                        continue
                    blocks_to_add.append(block)
                combined = text_boxes + blocks_to_add
                split = self._detect_two_column_split(combined, w)
                ordered_boxes = self._sort_boxes_reading_order(
                    combined, image_width=w, column_split=split
                )
            else:
                ordered_boxes = dbnet_boxes
                if not ordered_boxes:
                    ordered_boxes = [
                        b for b in layout_boxes if b["label"] != "image"
                    ]
        elif mode == "pp_doclayout_v2":
            ordered_boxes = [
                b
                for b in self._detect_pp_doclayout_v2(image, threshold=0.42)
                if b["label"] != "image"
            ]
            if not ordered_boxes:
                ordered_boxes = self._detect_dbnet(
                    image, mode="standard", merge_fragments=True
                )
        elif mode == "dense":
            ordered_boxes = self._detect_dbnet(
                image, mode="dense", merge_fragments=True
            )
        elif mode == "standard":
            ordered_boxes = self._detect_dbnet(
                image, mode="standard", merge_fragments=True
            )
        else:
            # Unknown modes are rejected at the API boundary; use standard
            # geometry rather than silently returning unmerged fragments.
            ordered_boxes = self._detect_dbnet(
                image, mode="standard", merge_fragments=True
            )

        if not ordered_boxes:
            ordered_boxes = [_full_image_box(w, h)]

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

# Preview and OCR send the same bytes. Cache the detection result so one
# click does not run the detector twice (and compare mode does not run it
# twice more). The cache is process-local and bounded.
_DETECTION_CACHE: "OrderedDict[tuple[str, str], dict]" = OrderedDict()
_DETECTION_CACHE_LOCK = threading.Lock()
_DETECTION_CACHE_MAX = 8


def _cached_detect(
    image: Image.Image,
    raw_bytes: Optional[bytes],
    mode: str,
    task: str = "ocr",
) -> dict:
    if raw_bytes:
        digest = hashlib.sha256(raw_bytes).hexdigest()
    else:
        digest = hashlib.sha256(image.tobytes()).hexdigest()
    key = (digest, mode, (task or "ocr").lower())
    with _DETECTION_CACHE_LOCK:
        cached = _DETECTION_CACHE.get(key)
        if cached is not None:
            _DETECTION_CACHE.move_to_end(key)
            result = dict(cached)
            result["cached"] = True
            return result
    result = detector_engine.detect(image, mode=mode, task=task)
    with _DETECTION_CACHE_LOCK:
        _DETECTION_CACHE[key] = result
        _DETECTION_CACHE.move_to_end(key)
        while len(_DETECTION_CACHE) > _DETECTION_CACHE_MAX:
            _DETECTION_CACHE.popitem(last=False)
    return result


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

        tokenizer = getattr(self.processor, "tokenizer", None)
        eos_token_id = getattr(tokenizer, "eos_token_id", None)
        last_token = (
            int(generated_ids[0, -1].item()) if num_tokens > 0 else None
        )
        truncated = num_tokens >= max_new_tokens and (
            eos_token_id is None or last_token != eos_token_id
        )

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
            "truncated": bool(truncated),
            "tokens": num_tokens,
            "tokens_per_sec": tokens_per_sec,
            "image_size": {"width": image.width, "height": image.height},
        }

    def _prepare_region(
        self,
        image: Image.Image,
        box: dict,
        prompt_text: str,
        max_new_tokens: int,
    ) -> tuple[Image.Image, str, str, str, int]:
        box_label = box.get("label", "text_line")
        crop_img, thumb_b64 = detector_engine.crop_and_enhance(
            image,
            box.get("crop_bbox") or box["bbox"],
            box_label=box_label,
        )
        box_prompt = (
            LAYOUT_LABEL_TO_PROMPT.get(box_label, prompt_text)
            if prompt_text == "OCR:"
            else prompt_text
        )
        if box_label == "text_line":
            budget = max(32, min(int(max_new_tokens), 384))
        else:
            budget = max(128, min(int(max_new_tokens), 2048))
        return crop_img, thumb_b64, box_label, box_prompt, budget

    def _generate_region(
        self,
        crop_img: Image.Image,
        box_label: str,
        box_prompt: str,
        budget: int,
        use_lora: bool,
    ) -> dict:
        total_tokens = 0
        total_ms = 0.0
        used_lora = False
        try:
            if box_label in LAYOUT_BASE_LABELS or box_prompt in BASE_REGION_PROMPTS:
                # Formula/table/chart blocks (including a task-level
                # full-image fallback) use the base model's native decoders;
                # the Khmer single-line adapter is not appropriate.
                res = self.predict(
                    image=crop_img,
                    prompt_text=box_prompt,
                    max_new_tokens=budget,
                    use_lora=False,
                )
            else:
                used_lora = bool(use_lora)
                res = self.predict(
                    image=crop_img,
                    prompt_text=box_prompt,
                    max_new_tokens=budget,
                    use_lora=used_lora,
                )
            total_tokens += int(res["tokens"])
            total_ms += float(res["elapsed_ms"])
            truncated = bool(
                res.get("truncated", int(res["tokens"]) >= budget)
            )

            # Per-region fallback, never a page-wide latch. A block that is
            # non-Khmer or hit the token cap is retried on the base model.
            if used_lora and box_label != "text_line" and (
                not _contains_khmer(res["text"]) or truncated
            ):
                try:
                    base_res = self.predict(
                        image=crop_img,
                        prompt_text=box_prompt,
                        max_new_tokens=budget,
                        use_lora=False,
                    )
                except Exception as fallback_exc:
                    # Keep the successful LoRA text instead of discarding it.
                    logger.warning(
                        f"Base fallback failed ({box_label}): {fallback_exc}"
                    )
                    base_res = None
                if base_res is not None:
                    total_tokens += int(base_res["tokens"])
                    total_ms += float(base_res["elapsed_ms"])
                    if (
                        _contains_khmer(base_res["text"])
                        or len(base_res["text"].strip())
                        > len(res["text"].strip())
                    ):
                        res = base_res
                        used_lora = False
                        truncated = bool(
                            base_res.get(
                                "truncated",
                                int(base_res["tokens"]) >= budget,
                            )
                        )

            return {
                "text": res["text"].strip(),
                "tokens": total_tokens,
                "elapsed_ms": round(total_ms, 1),
                "used_lora": used_lora,
                "truncated": bool(truncated),
                "error": None,
            }
        except Exception as exc:
            logger.warning(f"Region OCR error ({box_label}): {exc}")
            return {
                "text": "",
                "tokens": total_tokens,
                "elapsed_ms": round(total_ms, 1),
                "used_lora": used_lora,
                "truncated": False,
                "error": str(exc),
            }

    @staticmethod
    def _same_row_as_prev(prev_box: Optional[dict], box: dict) -> bool:
        if not prev_box:
            return False
        prev_b = prev_box["bbox"]
        cur_b = box["bbox"]
        prev_cy = (prev_b[1] + prev_b[3]) / 2.0
        cur_cy = (cur_b[1] + cur_b[3]) / 2.0
        prev_bh = max(1, prev_b[3] - prev_b[1])
        cur_bh = max(1, cur_b[3] - cur_b[1])
        gap = cur_b[0] - prev_b[2]
        max_gap = max(40.0, 0.8 * min(prev_bh, cur_bh))
        return (
            abs(cur_cy - prev_cy) < max(prev_bh, cur_bh) * 0.55
            and -25 <= gap <= max_gap
        )

    @staticmethod
    def _append_text_line(
        lines: list[str],
        regions: list[dict],
        text: str,
        same_row: bool,
    ) -> None:
        if not text:
            return
        # Only merge into the previous output line when the immediately
        # previous box actually produced text. Otherwise an empty region
        # could splice a later row into an earlier one.
        if same_row and lines and regions and regions[-1].get("text"):
            lines[-1] = f"{lines[-1]}    {text}"
        else:
            lines.append(text)

    def stream_regions_predict(
        self,
        image: Image.Image,
        prompt_text: str = "OCR:",
        max_new_tokens: int = 512,
        use_lora: bool = True,
        det_mode: str = "smart_hybrid",
        det_result: Optional[dict] = None,
        task: str = "ocr",
    ):
        t0 = time.perf_counter()
        try:
            if self.status != "ready" or self.model is None:
                raise RuntimeError(
                    f"Model is not ready (status: {self.status_message})"
                )
            if det_result is None:
                det_result = detector_engine.detect(image, mode=det_mode)
        except Exception as exc:
            logger.exception("Detection failed before region streaming")
            error_payload = json.dumps(
                {"type": "error", "error": str(exc)}, ensure_ascii=False
            )
            yield f"data: {error_payload}\n\n"
            return

        boxes = _filter_boxes_for_task(det_result["boxes"], task, image)

        det_event = json.dumps(
            {
                "type": "detections",
                "boxes": boxes,
                "det_elapsed_ms": det_result["elapsed_ms"],
                "det_cached": bool(det_result.get("cached", False)),
                "det_mode": det_mode,
            },
            ensure_ascii=False,
        )
        yield f"data: {det_event}\n\n"

        if not boxes:
            elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
            empty_payload = json.dumps(
                {
                    "type": "done",
                    "text": "",
                    "regions": [],
                    "prompt": prompt_text,
                    "use_lora": use_lora,
                    "model_id": LORA_MODEL_ID if use_lora else BASE_MODEL_ID,
                    "elapsed_ms": elapsed_ms,
                    "det_elapsed_ms": det_result["elapsed_ms"],
                    "det_cached": bool(det_result.get("cached", False)),
                    "tokens": 0,
                    "tokens_per_sec": 0.0,
                    "image_size": {"width": image.width, "height": image.height},
                },
                ensure_ascii=False,
            )
            yield f"data: {empty_payload}\n\n"
            return

        if det_mode == "none" or (
            len(boxes) == 1
            and boxes[0]["bbox"] == [0, 0, image.width, image.height]
        ):
            start_ev = json.dumps(
                {"type": "region_start", "index": 1, "total": 1, "box": boxes[0]},
                ensure_ascii=False,
            )
            yield f"data: {start_ev}\n\n"

            full_use_lora = (
                False if prompt_text in BASE_REGION_PROMPTS else use_lora
            )
            for chunk in self.stream_single_image(
                image, prompt_text, max_new_tokens, full_use_lora, boxes
            ):
                yield chunk
            return

        total_boxes = len(boxes)
        recognized_lines: list[str] = []
        region_results: list[dict] = []
        total_tokens = 0
        any_lora = False

        for idx, box in enumerate(boxes, start=1):
            same_row_as_prev = (
                idx > 1 and self._same_row_as_prev(boxes[idx - 2], box)
            )
            try:
                (
                    crop_img,
                    thumb_b64,
                    box_label,
                    box_prompt,
                    budget,
                ) = self._prepare_region(
                    image, box, prompt_text, max_new_tokens
                )
            except Exception as exc:
                logger.warning(f"Region preparation failed: {exc}")
                region_item = {
                    "id": box["id"],
                    "label": box.get("label", "text_line"),
                    "score": box.get("score", 1.0),
                    "bbox": box["bbox"],
                    "polygon": box["polygon"],
                    "text": "",
                    "same_row_as_prev": same_row_as_prev,
                    "elapsed_ms": 0.0,
                    "thumb": None,
                    "truncated": False,
                    "error": str(exc),
                    "adapter": "none",
                }
                region_results.append(region_item)
                yield f"data: {json.dumps({'type': 'region_done', 'index': idx, 'total': total_boxes, 'region': region_item}, ensure_ascii=False)}\n\n"
                continue

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

            res = self._generate_region(
                crop_img, box_label, box_prompt, budget, use_lora
            )
            total_tokens += res["tokens"]
            any_lora = any_lora or res["used_lora"]

            self._append_text_line(
                recognized_lines,
                region_results,
                res["text"],
                same_row_as_prev,
            )

            region_item = {
                "id": box["id"],
                "label": box_label,
                "score": box.get("score", 1.0),
                "bbox": box["bbox"],
                "polygon": box["polygon"],
                "text": res["text"],
                "same_row_as_prev": same_row_as_prev,
                "elapsed_ms": res["elapsed_ms"],
                "thumb": thumb_b64,
                "truncated": res["truncated"],
                "error": res["error"],
                "adapter": "lora" if res["used_lora"] else "base",
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
                "use_lora": any_lora if region_results else use_lora,
                "model_id": (
                    LORA_MODEL_ID
                    if (any_lora if region_results else use_lora)
                    else BASE_MODEL_ID
                ),
                "elapsed_ms": elapsed_ms,
                "det_elapsed_ms": det_result["elapsed_ms"],
                "det_cached": bool(det_result.get("cached", False)),
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
        try:
            inputs = self.prepare_inputs(image, prompt_text)
        except Exception as exc:
            logger.warning(f"Full-image input preparation failed: {exc}")
            yield f"data: {json.dumps({'type': 'error', 'error': str(exc)}, ensure_ascii=False)}\n\n"
            return

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
            "same_row_as_prev": False,
            "elapsed_ms": elapsed_ms,
            "truncated": chunk_count >= max_new_tokens,
            "error": generation_error[0] if generation_error else None,
            "adapter": "lora" if use_lora else "base",
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
    docs_url=None if API_ONLY else "/docs",
    redoc_url=None if API_ONLY else "/redoc",
    openapi_url=None if API_ONLY else "/openapi.json",
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=OCR_ALLOWED_ORIGINS,
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


if API_ONLY:
    @app.middleware("http")
    async def require_api_key(request, call_next):
        # Let CORS handle browser preflight requests. Browsers cannot attach the
        # x-api-key value to OPTIONS, so checking it here would block Flutter Web.
        if request.method == "OPTIONS":
            return await call_next(request)

        if not request.url.path.startswith("/api/"):
            return JSONResponse(status_code=404, content={"detail": "Not found"})

        expected_key = os.environ.get("OPENKHMER_API_KEY")
        if not expected_key:
            return JSONResponse(
                status_code=503,
                content={"detail": "API key is not configured on the server"},
            )

        supplied_key = request.headers.get("x-api-key", "")
        if not hmac.compare_digest(
            supplied_key.encode("utf-8"), expected_key.encode("utf-8")
        ):
            return JSONResponse(status_code=401, content={"detail": "Invalid API key"})

        return await call_next(request)


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


def _validate_det_mode(det_mode: str) -> None:
    if det_mode not in VALID_DET_MODES:
        raise HTTPException(
            status_code=400,
            detail=(
                f"Unknown detection mode {det_mode!r}. "
                f"Expected one of: {', '.join(sorted(VALID_DET_MODES))}"
            ),
        )


def _select_requested_regions(boxes: list[dict], region_ids: Optional[str]) -> list[dict]:
    """Restrict OCR to detector-issued IDs when a client explicitly selects regions."""
    if region_ids is None or region_ids == "":
        return boxes
    try:
        requested = json.loads(region_ids)
    except (TypeError, json.JSONDecodeError) as exc:
        raise HTTPException(status_code=400, detail="region_ids must be a JSON array.") from exc
    if not isinstance(requested, list) or any(not isinstance(value, (str, int)) for value in requested):
        raise HTTPException(status_code=400, detail="region_ids must be a JSON array of IDs.")
    selected = {str(value) for value in requested}
    return [box for box in boxes if str(box.get("id", "")) in selected]


@app.post("/api/detect")
async def detect_regions(
    file: UploadFile = File(...),
    det_mode: str = Form("smart_hybrid"),
    task: str = Form("ocr"),
):
    _validate_det_mode(det_mode)
    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    try:
        result = await asyncio.to_thread(
            _cached_detect, image, raw_bytes, det_mode, task
        )
        # Preview exactly the regions the matching OCR task will process.
        result = dict(result)
        result["boxes"] = _filter_boxes_for_task(result["boxes"], task, image)
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
    region_ids: Optional[str] = Form(None),
):
    if model_manager.status != "ready":
        raise HTTPException(
            status_code=503,
            detail=f"Model is currently {model_manager.status}: {model_manager.status_message}",
        )

    _validate_det_mode(det_mode)
    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    prompt_text = _resolve_prompt(task, custom_prompt)
    max_tokens = max(32, min(int(max_new_tokens), 4096))

    def _run_region_ocr():
        t0 = time.perf_counter()
        det_res = _cached_detect(image, raw_bytes, det_mode, task)
        boxes = _filter_boxes_for_task(det_res["boxes"], task, image)
        boxes = _select_requested_regions(boxes, region_ids)
        lines: list[str] = []
        regions: list[dict] = []
        total_tok = 0
        for idx, box in enumerate(boxes, start=1):
            (
                crop_img,
                thumb_b64,
                box_label,
                box_prompt,
                budget,
            ) = model_manager._prepare_region(
                image, box, prompt_text, max_tokens
            )
            res = model_manager._generate_region(
                crop_img, box_label, box_prompt, budget, use_lora
            )
            total_tok += res["tokens"]
            same_row_as_prev = (
                idx > 1 and model_manager._same_row_as_prev(boxes[idx - 2], box)
            )
            model_manager._append_text_line(
                lines, regions, res["text"], same_row_as_prev
            )
            regions.append(
                {
                    "id": box["id"],
                    "label": box_label,
                    "score": box.get("score", 1.0),
                    "bbox": box["bbox"],
                    "polygon": box["polygon"],
                    "text": res["text"],
                    "same_row_as_prev": same_row_as_prev,
                    "elapsed_ms": res["elapsed_ms"],
                    "thumb": thumb_b64,
                    "truncated": res["truncated"],
                    "error": res["error"],
                    "adapter": "lora" if res["used_lora"] else "base",
                }
            )
        elapsed_ms = round((time.perf_counter() - t0) * 1000, 1)
        effective_lora = (
            any(region["adapter"] == "lora" for region in regions)
            if regions
            else use_lora
        )
        return {
            "text": "\n".join(lines),
            "regions": regions,
            "prompt": prompt_text,
            "use_lora": effective_lora,
            "model_id": LORA_MODEL_ID if effective_lora else BASE_MODEL_ID,
            "elapsed_ms": elapsed_ms,
            "det_elapsed_ms": det_res["elapsed_ms"],
            "det_cached": bool(det_res.get("cached", False)),
            "tokens": total_tok,
            "tokens_per_sec": (
                round(total_tok / (elapsed_ms / 1000.0), 1)
                if elapsed_ms > 0
                else 0.0
            ),
            "image_size": {"width": image.width, "height": image.height},
        }

    try:
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
    region_ids: Optional[str] = Form(None),
):
    if model_manager.status != "ready":
        raise HTTPException(
            status_code=503,
            detail=f"Model is currently {model_manager.status}: {model_manager.status_message}",
        )

    _validate_det_mode(det_mode)
    raw_bytes = await file.read()
    image = _read_pil_image(raw_bytes)
    prompt_text = _resolve_prompt(task, custom_prompt)
    max_tokens = max(32, min(int(max_new_tokens), 4096))

    # Detect before sending SSE headers so a detector failure is a real 500
    # instead of a truncated 200 stream.
    try:
        det_result = await asyncio.to_thread(
            _cached_detect, image, raw_bytes, det_mode, task
        )
        det_result = dict(det_result)
        det_result["boxes"] = _select_requested_regions(
            _filter_boxes_for_task(det_result["boxes"], task, image), region_ids
        )
    except Exception as exc:
        logger.exception("Text detection error before stream")
        raise HTTPException(status_code=500, detail=str(exc)) from exc

    return StreamingResponse(
        model_manager.stream_regions_predict(
            image=image,
            prompt_text=prompt_text,
            max_new_tokens=max_tokens,
            use_lora=use_lora,
            det_mode=det_mode,
            det_result=det_result,
            task=task,
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


if not API_ONLY:
    os.makedirs("static", exist_ok=True)
    app.mount("/static", StaticFiles(directory="static"), name="static")

    @app.get("/")
    async def serve_index():
        return FileResponse("static/index.html")


if __name__ == "__main__":
    import uvicorn

    uvicorn.run("app:app", host="0.0.0.0", port=PORT, reload=False)
