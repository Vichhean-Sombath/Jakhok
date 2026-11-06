import inspect
import json
import sys
import unittest
from pathlib import Path
from unittest import mock

PROJECT_ROOT = Path(__file__).resolve().parents[1]
if str(PROJECT_ROOT) not in sys.path:
    sys.path.insert(0, str(PROJECT_ROOT))

import app  # noqa: E402
import numpy as np  # noqa: E402
from PIL import Image, ImageDraw  # noqa: E402


def box(x1, y1, x2, y2, label="text_line", score=1.0):
    return {
        "id": 0,
        "label": label,
        "score": score,
        "bbox": [x1, y1, x2, y2],
        "polygon": [[x1, y1], [x2, y1], [x2, y2], [x1, y2]],
    }


class DetectionGeometryTests(unittest.TestCase):
    def test_iou_and_containment(self):
        outer = [0, 0, 100, 100]
        inner = [25, 25, 75, 75]
        self.assertAlmostEqual(app._box_iou(outer, inner), 2500 / 10000)
        self.assertAlmostEqual(app._box_containment(outer, inner), 1.0)

    def test_two_column_order_is_column_major(self):
        boxes = [box(50, 100 + i * 40, 400, 130 + i * 40) for i in range(4)]
        boxes += [box(600, 100 + i * 40, 950, 130 + i * 40) for i in range(4)]
        ordered = app.TextDetectorEngine._sort_boxes_reading_order(
            boxes, image_width=1000, column_split=500
        )
        self.assertEqual(len(ordered), 8)
        self.assertTrue(all(b["bbox"][0] < 500 for b in ordered[:4]))
        self.assertTrue(all(b["bbox"][0] >= 500 for b in ordered[4:]))
        self.assertEqual([b["id"] for b in ordered], list(range(1, 9)))

    def test_midpage_spanning_block_keeps_reading_bands(self):
        left = [box(50, 100 + i * 60, 450, 140 + i * 60) for i in range(5)]
        right = [box(550, 100 + i * 60, 950, 140 + i * 60) for i in range(5)]
        span = box(50, 245, 950, 265)
        ordered = app.TextDetectorEngine._sort_boxes_reading_order(
            left + right + [span],
            image_width=1000,
            allow_two_column=True,
        )
        span_index = ordered.index(span)
        before = ordered[:span_index]
        after = ordered[span_index + 1 :]
        self.assertEqual(len(before), 6)  # three left + three right above
        self.assertTrue(all(b["bbox"][1] < 245 for b in before))
        self.assertTrue(all(b["bbox"][3] > 265 for b in after))

    def test_centered_narrow_box_is_not_duplicated(self):
        boxes = [box(50, 100 + i * 40, 450, 130 + i * 40) for i in range(4)]
        boxes += [box(550, 100 + i * 40, 950, 130 + i * 40) for i in range(4)]
        boxes.append(box(495, 100, 505, 130))
        ordered = app.TextDetectorEngine._sort_boxes_reading_order(
            boxes, image_width=1000, allow_two_column=True
        )
        self.assertEqual(len(ordered), len(boxes))
        self.assertEqual(len({id(b) for b in ordered}), len(ordered))
        self.assertEqual(len({b["id"] for b in ordered}), len(ordered))

    def test_auto_two_column_split(self):
        boxes = [box(50, 100 + i * 40, 450, 130 + i * 40) for i in range(6)]
        boxes += [box(550, 100 + i * 40, 950, 130 + i * 40) for i in range(6)]
        split = app.TextDetectorEngine._detect_two_column_split(boxes, 1000)
        self.assertIsNotNone(split)
        self.assertAlmostEqual(split, 500, delta=20)

    def test_centered_title_does_not_break_two_column_split(self):
        boxes = [box(50, 100 + i * 40, 450, 130 + i * 40) for i in range(6)]
        boxes += [box(550, 100 + i * 40, 950, 130 + i * 40) for i in range(6)]
        boxes.append(box(200, 20, 800, 70))  # full-width title
        split = app.TextDetectorEngine._detect_two_column_split(boxes, 1000)
        self.assertIsNotNone(split)
        self.assertAlmostEqual(split, 500, delta=20)

    def test_form_columns_are_not_two_column_text(self):
        boxes = []
        for row in range(6):
            y = 100 + row * 60
            boxes.append(box(50, y, 200, y + 40))    # label
            boxes.append(box(300, y, 800, y + 40))   # value
        self.assertIsNone(
            app.TextDetectorEngine._detect_two_column_split(boxes, 1000)
        )

    def test_table_rules_reject_two_column_split(self):
        boxes = [box(50, 100 + i * 60, 350, 140 + i * 60) for i in range(6)]
        boxes += [box(450, 100 + i * 60, 750, 140 + i * 60) for i in range(6)]
        gray = np.full((500, 800), 255, dtype=np.uint8)
        for y in (20, 40, 60, 80):
            gray[y, :] = 0
        self.assertIsNone(
            app.TextDetectorEngine._detect_two_column_split(
                boxes, 1000, gray=gray
            )
        )

    def test_table_grid_is_not_a_two_column_split(self):
        boxes = []
        for r in range(4):
            for c in range(5):
                x = 100 + c * 80
                boxes.append(box(x, 100 + r * 60, x + 70, 140 + r * 60))
        self.assertIsNone(
            app.TextDetectorEngine._detect_two_column_split(boxes, 1000)
        )

    def test_merge_does_not_cross_recurring_gutter(self):
        boxes = []
        for row in range(4):
            y = 100 + row * 60
            boxes.append(box(100, y, 180, y + 40))
            boxes.append(box(190, y, 270, y + 40))
        merged = app.TextDetectorEngine._merge_horizontal_line_fragments(
            boxes, image_width=1000
        )
        self.assertEqual(len(merged), 8)
        self.assertFalse(
            any(b["bbox"][0] < 185 < b["bbox"][2] for b in merged)
        )

    def test_merge_joins_tight_same_line_fragments(self):
        boxes = [box(100, 100, 180, 140), box(190, 100, 260, 140)]
        merged = app.TextDetectorEngine._merge_horizontal_line_fragments(
            boxes, image_width=1000
        )
        self.assertEqual(len(merged), 1)
        self.assertEqual(merged[0]["bbox"], [100, 100, 260, 140])

    def test_merge_does_not_cross_vertical_rule(self):
        image = Image.new("RGB", (300, 100), "white")
        draw = ImageDraw.Draw(image)
        draw.rectangle([108, 15, 110, 65], fill="black")  # cell border
        gray = np.array(image.convert("L"))
        boxes = [box(50, 20, 100, 60), box(120, 20, 170, 60)]
        merged = app.TextDetectorEngine._merge_horizontal_line_fragments(
            boxes, image_width=300, gray=gray
        )
        self.assertEqual(len(merged), 2)

    def test_punctuation_expansion_rejects_long_rule(self):
        image = Image.new("RGB", (400, 100), "white")
        draw = ImageDraw.Draw(image)
        draw.rectangle([60, 30, 300, 50], fill="black")
        draw.rectangle([5, 40, 355, 42], fill="black")  # 2 px rule
        item = box(60, 20, 300, 60)
        result = app.TextDetectorEngine._expand_line_punctuation_margins(
            [item], image
        )
        self.assertEqual(result[0]["bbox"], [60, 20, 300, 60])

    def test_punctuation_expansion_accepts_near_mark(self):
        image = Image.new("RGB", (240, 100), "white")
        draw = ImageDraw.Draw(image)
        draw.rectangle([60, 30, 150, 50], fill="black")
        draw.rectangle([156, 30, 162, 50], fill="black")
        item = box(50, 20, 150, 60)
        result = app.TextDetectorEngine._expand_line_punctuation_margins(
            [item], image
        )
        self.assertGreater(result[0]["bbox"][2], 150)
        self.assertLessEqual(result[0]["bbox"][2], 150 + 20)

    def test_deoverlap_trims_sliver_overlap(self):
        first = box(100, 100, 300, 150)
        second = box(100, 145, 300, 195)
        result = app.TextDetectorEngine._deoverlap_vertical_boxes(
            [first, second]
        )
        self.assertLessEqual(result[0]["bbox"][3], result[1]["bbox"][1])

    def test_detection_scale_is_bounded(self):
        a4 = app._compute_det_scale(2480, 3508, 1280, 2000, 4_000_000)
        self.assertLessEqual(3508 * a4, 2001)
        self.assertLessEqual(2480 * a4 * 3508 * a4, 4_000_000)
        small = app._compute_det_scale(600, 400, 1280, 2000, 4_000_000)
        self.assertGreater(small, 1.0)
        self.assertLessEqual(600 * small, 2001)
        strip = app._compute_det_scale(100, 2000, 1280, 2000, 4_000_000)
        self.assertEqual(strip, 1.0)
        self.assertLessEqual(100 * strip * 2000 * strip, 4_000_000)


class LayoutNmsTests(unittest.TestCase):
    def test_contained_same_label_duplicate_is_dropped(self):
        giant = box(100, 100, 900, 2000, label="text", score=0.48)
        lines = [
            box(120, 120 + i * 60, 880, 170 + i * 60, label="text", score=0.62)
            for i in range(20)
        ]
        kept = app.TextDetectorEngine._nms_layout([giant] + lines)
        self.assertNotIn(giant, kept)
        self.assertEqual(len(kept), 20)

    def test_text_inside_table_is_suppressed(self):
        table = box(100, 100, 900, 700, label="table", score=0.9)
        inside = box(120, 120, 880, 200, label="text", score=0.8)
        outside = box(100, 720, 900, 780, label="text", score=0.8)
        kept = app.TextDetectorEngine._suppress_text_inside_blocks(
            [table, inside, outside]
        )
        self.assertIn(table, kept)
        self.assertNotIn(inside, kept)
        self.assertIn(outside, kept)

    def test_formula_inside_text_is_kept(self):
        text = box(100, 100, 900, 800, label="text", score=0.90)
        formula = box(300, 300, 600, 380, label="formula", score=0.70)
        kept = app.TextDetectorEngine._nms_layout([text, formula])
        self.assertIn(text, kept)
        self.assertIn(formula, kept)


class DetectionRoutingTests(unittest.TestCase):
    def test_label_prompts_and_base_routing(self):
        self.assertEqual(
            app.LAYOUT_LABEL_TO_PROMPT["table"], "Table Recognition:"
        )
        self.assertEqual(
            app.LAYOUT_LABEL_TO_PROMPT["chart"], "Chart Recognition:"
        )
        self.assertIn("table", app.LAYOUT_BASE_LABELS)
        self.assertIn("chart", app.LAYOUT_BASE_LABELS)
        self.assertIn("formula", app.LAYOUT_BASE_LABELS)

    def test_skip_labels_match_checkpoint(self):
        self.assertEqual(app.LAYOUT_SKIP_LABELS, {"header", "footer", "number"})

    def test_same_row_rejects_wide_column_gap(self):
        previous = box(100, 10, 420, 50)
        far = box(520, 10, 950, 50)
        near = box(430, 10, 950, 50)
        self.assertFalse(
            app.ModelManager._same_row_as_prev(previous, far)
        )
        self.assertTrue(
            app.ModelManager._same_row_as_prev(previous, near)
        )

    def test_same_row_append_requires_previous_text(self):
        lines = ["first row"]
        regions = [{"text": ""}]
        app.ModelManager._append_text_line(lines, regions, "late text", True)
        self.assertEqual(lines, ["first row", "late text"])

    def test_same_row_append_merges_after_text(self):
        lines = ["first row"]
        regions = [{"text": "first row"}]
        app.ModelManager._append_text_line(lines, regions, "same row", True)
        self.assertEqual(lines, ["first row    same row"])

    def test_valid_det_modes(self):
        self.assertEqual(
            app.VALID_DET_MODES,
            {"smart_hybrid", "pp_doclayout_v2", "standard", "dense", "none"},
        )

    def test_prepare_region_prompts_and_budgets(self):
        image = Image.new("RGB", (200, 80), "white")
        manager = object.__new__(app.ModelManager)
        table_crop, _, label, prompt, budget = manager._prepare_region(
            image,
            box(10, 10, 190, 70, label="table"),
            prompt_text="OCR:",
            max_new_tokens=1024,
        )
        self.assertEqual(label, "table")
        self.assertEqual(prompt, "Table Recognition:")
        self.assertEqual(budget, 1024)
        line_crop, _, label, prompt, budget = manager._prepare_region(
            image,
            box(10, 10, 190, 70, label="text_line"),
            prompt_text="OCR:",
            max_new_tokens=1024,
        )
        self.assertEqual(label, "text_line")
        self.assertEqual(prompt, "OCR:")
        self.assertEqual(budget, 384)

    def test_lora_fallback_is_per_region_not_page_wide(self):
        class DummyManager:
            def __init__(self, outputs):
                self.outputs = list(outputs)
                self.calls = []

            def predict(self, **kwargs):
                self.calls.append(
                    (kwargs["use_lora"], kwargs["prompt_text"])
                )
                return self.outputs.pop(0)

        image = Image.new("RGB", (100, 40), "white")
        manager = DummyManager(
            [
                {"text": "", "tokens": 10, "elapsed_ms": 1.0},
                {"text": "english base", "tokens": 20, "elapsed_ms": 2.0},
                {"text": "ខ្មែរ", "tokens": 8, "elapsed_ms": 1.0},
            ]
        )
        first = app.ModelManager._generate_region(
            manager, image, "text", "OCR:", 100, True
        )
        second = app.ModelManager._generate_region(
            manager, image, "text", "OCR:", 100, True
        )
        self.assertFalse(first["used_lora"])
        self.assertEqual(first["text"], "english base")
        self.assertTrue(second["used_lora"])
        self.assertEqual(second["text"], "ខ្មែរ")
        self.assertEqual(
            manager.calls,
            [
                (True, "OCR:"),
                (False, "OCR:"),
                (True, "OCR:"),
            ],
        )

    def test_formula_block_uses_base_model_only(self):
        class DummyManager:
            def __init__(self):
                self.calls = []

            def predict(self, **kwargs):
                self.calls.append(kwargs["use_lora"])
                return {"text": "x^2", "tokens": 4, "elapsed_ms": 1.0}

        manager = DummyManager()
        result = app.ModelManager._generate_region(
            manager,
            Image.new("RGB", (100, 40), "white"),
            "formula",
            "Formula Recognition:",
            100,
            True,
        )
        self.assertEqual(manager.calls, [False])
        self.assertFalse(result["used_lora"])
        self.assertEqual(result["text"], "x^2")

    def test_smart_hybrid_keeps_db_lines_and_adds_blocks(self):
        image = Image.new("RGB", (1000, 800), "white")
        layout_boxes = [
            box(100, 100, 900, 400, label="text", score=0.9),
            box(120, 450, 880, 520, label="formula", score=0.8),
            box(100, 560, 900, 760, label="table", score=0.8),
        ]
        db_boxes = [
            box(110, 110, 880, 150, label="text_line", score=1.0),
            box(130, 460, 860, 510, label="text_line", score=1.0),
            box(115, 580, 880, 620, label="text_line", score=1.0),
        ]
        with mock.patch.object(
            app.detector_engine,
            "_detect_pp_doclayout_v2",
            return_value=layout_boxes,
        ), mock.patch.object(
            app.detector_engine,
            "_detect_dbnet",
            return_value=db_boxes,
        ):
            ocr_result = app.detector_engine.detect(
                image, mode="smart_hybrid", task="ocr"
            )
        ocr_labels = [b["label"] for b in ocr_result["boxes"]]
        self.assertEqual(ocr_labels.count("formula"), 1)
        self.assertEqual(ocr_labels.count("table"), 0)
        self.assertNotIn("text", ocr_labels)
        # OCR keeps DB lines inside a table block; only the display formula
        # replaces its line.
        self.assertEqual(ocr_labels.count("text_line"), 2)
        self.assertIn(
            [110, 110, 880, 150], [b["bbox"] for b in ocr_result["boxes"]]
        )

        with mock.patch.object(
            app.detector_engine,
            "_detect_pp_doclayout_v2",
            return_value=layout_boxes,
        ), mock.patch.object(
            app.detector_engine,
            "_detect_dbnet",
            return_value=db_boxes,
        ):
            table_result = app.detector_engine.detect(
                image, mode="smart_hybrid", task="table"
            )
        table_labels = [b["label"] for b in table_result["boxes"]]
        self.assertEqual(table_labels.count("table"), 1)
        self.assertEqual(table_labels.count("formula"), 1)
        self.assertEqual(table_labels.count("text_line"), 1)

    def test_stream_regions_contract_with_fake_model(self):
        boxes = [
            box(10, 10, 90, 50),
            box(100, 10, 180, 50),
        ]
        det_result = {"mode": "standard", "elapsed_ms": 1.0, "boxes": boxes}
        outputs = iter(
            [
                {"text": "A", "tokens": 2, "elapsed_ms": 1.0},
                {"text": "B", "tokens": 2, "elapsed_ms": 1.0},
            ]
        )

        def fake_predict(**kwargs):
            return next(outputs)

        with mock.patch.object(app.model_manager, "status", "ready"), mock.patch.object(
            app.model_manager, "model", object()
        ), mock.patch.object(
            app.model_manager, "predict", side_effect=fake_predict
        ):
            events = []
            for chunk in app.model_manager.stream_regions_predict(
                Image.new("RGB", (200, 80), "white"),
                prompt_text="OCR:",
                max_new_tokens=512,
                use_lora=True,
                det_mode="standard",
                det_result=det_result,
            ):
                assert chunk.startswith("data: ")
                events.append(json.loads(chunk[6:].strip()))

        region_events = [e for e in events if e["type"] == "region_done"]
        done = [e for e in events if e["type"] == "done"][0]
        self.assertEqual(len(region_events), 2)
        self.assertEqual(done["text"], "A    B")
        self.assertFalse(region_events[0]["region"]["same_row_as_prev"])
        self.assertTrue(region_events[1]["region"]["same_row_as_prev"])
        self.assertEqual(region_events[1]["region"]["adapter"], "lora")
        self.assertIsNone(region_events[1]["region"]["error"])

    def test_inline_formula_does_not_delete_text_line(self):
        image = Image.new("RGB", (1000, 400), "white")
        layout_boxes = [
            box(300, 110, 500, 140, label="formula", score=0.8),
        ]
        db_boxes = [
            box(110, 100, 880, 150, label="text_line", score=1.0),
        ]
        with mock.patch.object(
            app.detector_engine,
            "_detect_pp_doclayout_v2",
            return_value=layout_boxes,
        ), mock.patch.object(
            app.detector_engine, "_detect_dbnet", return_value=db_boxes
        ):
            result = app.detector_engine.detect(image, mode="smart_hybrid")
        self.assertEqual([b["label"] for b in result["boxes"]], ["text_line"])

    def test_dense_mode_uses_dense_engine(self):
        image = Image.new("RGB", (200, 100), "white")
        with mock.patch.object(
            app.detector_engine, "_detect_dbnet", return_value=[]
        ) as detect_dbnet:
            app.detector_engine.detect(image, mode="dense")
        self.assertEqual(detect_dbnet.call_args.kwargs["mode"], "dense")

    def test_task_selects_matching_blocks(self):
        image = Image.new("RGB", (500, 400), "white")
        boxes = [
            box(10, 10, 490, 100, label="text_line"),
            box(10, 120, 490, 300, label="table"),
            box(10, 320, 490, 380, label="formula"),
        ]
        self.assertEqual(
            len(app._filter_boxes_for_task(boxes, "ocr", image)), 3
        )
        table_only = app._filter_boxes_for_task(boxes, "table", image)
        self.assertEqual([b["label"] for b in table_only], ["table"])
        formula_only = app._filter_boxes_for_task(boxes, "formula", image)
        self.assertEqual([b["label"] for b in formula_only], ["formula"])
        fallback = app._filter_boxes_for_task(
            [boxes[0]], "table", image
        )
        self.assertEqual([b["label"] for b in fallback], ["full_image"])

    def test_task_prompt_forces_base_model(self):
        class DummyManager:
            def __init__(self):
                self.calls = []

            def predict(self, **kwargs):
                self.calls.append(kwargs["use_lora"])
                return {"text": "table text", "tokens": 3, "elapsed_ms": 1.0}

        manager = DummyManager()
        result = app.ModelManager._generate_region(
            manager,
            Image.new("RGB", (100, 40), "white"),
            "full_image",
            "Table Recognition:",
            512,
            True,
        )
        self.assertEqual(manager.calls, [False])
        self.assertFalse(result["used_lora"])

    def test_base_fallback_failure_preserves_lora_text(self):
        class DummyManager:
            def __init__(self):
                self.calls = 0

            def predict(self, **kwargs):
                self.calls += 1
                if self.calls == 1:
                    return {
                        "text": "ខ្មែរ",
                        "tokens": 100,
                        "elapsed_ms": 1.0,
                        "truncated": True,
                    }
                raise RuntimeError("base failed")

        result = app.ModelManager._generate_region(
            DummyManager(),
            Image.new("RGB", (100, 40), "white"),
            "text",
            "OCR:",
            100,
            True,
        )
        self.assertEqual(result["text"], "ខ្មែរ")
        self.assertIsNone(result["error"])
        self.assertTrue(result["used_lora"])
        self.assertTrue(result["truncated"])

    def test_generate_region_error_is_reported(self):
        class DummyManager:
            def predict(self, **kwargs):
                raise RuntimeError("boom")

        result = app.ModelManager._generate_region(
            DummyManager(),
            Image.new("RGB", (100, 40), "white"),
            "text_line",
            "OCR:",
            100,
            True,
        )
        self.assertEqual(result["text"], "")
        self.assertIn("boom", result["error"])

    def test_stream_detection_failure_emits_error_event(self):
        with mock.patch.object(app.model_manager, "status", "ready"), mock.patch.object(
            app.model_manager, "model", object()
        ), mock.patch.object(
            app.detector_engine,
            "detect",
            side_effect=RuntimeError("detector down"),
        ):
            chunks = list(
                app.model_manager.stream_regions_predict(
                    Image.new("RGB", (100, 40), "white"),
                    det_mode="standard",
                )
            )
        self.assertEqual(len(chunks), 1)
        event = json.loads(chunks[0][6:].strip())
        self.assertEqual(event["type"], "error")
        self.assertIn("detector down", event["error"])

    def test_has_table_rules(self):
        gray = np.full((100, 120), 255, dtype=np.uint8)
        self.assertFalse(app.TextDetectorEngine._has_table_rules(gray))
        for y in (10, 30, 50):
            gray[y, :] = 0
        self.assertTrue(app.TextDetectorEngine._has_table_rules(gray))

    def test_predict_is_a_regular_function(self):
        # A stray `yield` in predict() would turn its return value into a
        # generator and break every region with "'generator' is not
        # subscriptable".
        self.assertFalse(
            inspect.isgeneratorfunction(app.ModelManager.predict)
        )
        self.assertTrue(
            inspect.isgeneratorfunction(
                app.ModelManager.stream_regions_predict
            )
        )
        self.assertTrue(
            inspect.isgeneratorfunction(app.ModelManager.stream_single_image)
        )

    def test_detection_cache_is_reused(self):
        app._DETECTION_CACHE.clear()
        payload = b"unique-detection-cache-test"
        image = Image.new("RGB", (40, 30), "white")
        fake_result = {"mode": "standard", "elapsed_ms": 1.0, "boxes": []}
        with mock.patch.object(
            app.detector_engine, "detect", return_value=fake_result
        ) as detect:
            first = app._cached_detect(image, payload, "standard")
            second = app._cached_detect(image, payload, "standard")
        self.assertEqual(detect.call_count, 1)
        self.assertFalse(first.get("cached", False))
        self.assertTrue(second.get("cached", False))
        app._DETECTION_CACHE.clear()


if __name__ == "__main__":
    unittest.main()
