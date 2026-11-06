import ast
import json
import os
import tempfile
import types
import unittest
from pathlib import Path
from unittest.mock import patch

import checkpoint_sync as sync


REPO_ID = "dvdphobia/OpenKhmer-Private-Checkpoints"
BASE_MODEL_ID = "unsloth/PaddleOCR-VL"
REVISION_A = "a" * 40
REVISION_B = "b" * 40
TOKEN = "offline-test-token-must-not-be-written"
PROJECT_ROOT = Path(__file__).resolve().parents[1]


def test_tempdir():
    # Use the authorized workspace; the system temp directory is sandboxed.
    return tempfile.TemporaryDirectory(dir=PROJECT_ROOT)


def make_state(*, step=2400, parent_run=sync.A100_PARENT_RUN_ID, parent_step=sync.A100_PARENT_STEP):
    return {
        "run_id": sync.DEFAULT_A100_RUN_ID,
        "run_fingerprint": sync.DEFAULT_A100_RUN_ID + ("f" * 48),
        "optimizer_step": step,
        "training_phase": "legacy-adapter-warm-start",
        "checkpoint_schema_version": 2,
        "ema_adapter_path": "adapter",
        "live_adapter_path": "adapter_live",
        "world_size": 1,
        "warm_start_source": {
            "source_run_id": parent_run,
            "optimizer_step": parent_step,
            "repo_path": f"runs/{parent_run}/checkpoint-latest",
        },
    }


def write_mock_snapshot(root: Path, *, state=None, weight_bytes=b"mock-weight-bytes") -> Path:
    phase = root / "runs" / sync.DEFAULT_A100_RUN_ID / "checkpoint-latest"
    adapter = phase / "adapter"
    adapter.mkdir(parents=True)
    (phase / "state.json").write_text(json.dumps(state or make_state()), encoding="utf-8")
    config = {
        "peft_type": "LORA",
        "base_model_name_or_path": BASE_MODEL_ID,
        "target_modules": ["q_proj"],
        "r": 16,
        "lora_alpha": 16,
    }
    (adapter / "adapter_config.json").write_text(json.dumps(config), encoding="utf-8")
    (adapter / "adapter_model.safetensors").write_bytes(weight_bytes)
    (adapter / "tokenizer_config.json").write_text("{}", encoding="utf-8")
    # These files must never be copied into or selected as the inference adapter.
    (phase / "optimizer.pt").write_bytes(b"optimizer")
    (phase / "adapter_live").mkdir()
    (phase / "adapter_live" / "adapter_model.safetensors").write_bytes(b"live")
    return root


class FakeSafeOpen:
    def __init__(self, *_args, **_kwargs):
        pass

    def __enter__(self):
        return self

    def __exit__(self, *_args):
        return False

    def keys(self):
        keys = []
        for index in range(162):
            prefix = f"base_model.model.visual.blocks.{index}.attn.q_proj"
            keys.extend([f"{prefix}.lora_A.weight", f"{prefix}.lora_B.weight"])
        for index in range(126):
            prefix = f"base_model.model.model.language_model.layers.{index}.mlp.down_proj"
            keys.extend([f"{prefix}.lora_A.weight", f"{prefix}.lora_B.weight"])
        return keys

    def get_slice(self, key):
        shape = (16, 3072) if ".lora_A." in key else (1024, 16)
        return types.SimpleNamespace(get_shape=lambda: shape)


class CheckpointSyncTests(unittest.TestCase):
    def test_a100_phase_step_is_not_ranked_against_parent_step(self):
        info = sync.validate_checkpoint_state(make_state(), sync.DEFAULT_A100_RUN_ID)
        self.assertEqual(info["optimizer_step"], 2400)
        self.assertEqual(info["parent_optimizer_step"], 157938)
        phase_dir, _adapter_dir = sync._phase_paths(
            Path("checkpoints"), sync.DEFAULT_A100_RUN_ID, info["optimizer_step"], "c" * 64,
        )
        self.assertIn("phase-step-000002400-", str(phase_dir))
        self.assertNotIn("157938", str(phase_dir))

    def test_lora_headers_have_complete_pairs_and_both_model_roots(self):
        keys = FakeSafeOpen().keys()
        self.assertEqual(len(keys), 576)
        self.assertEqual(sum(".lora_A." in key for key in keys), 288)
        self.assertEqual(sum(".lora_B." in key for key in keys), 288)
        self.assertEqual(sum(".visual." in key for key in keys), 324)
        self.assertEqual(sum(".language_model." in key for key in keys), 252)

        def shape_for_key(key):
            return (16, 3072) if ".lora_A." in key else (1024, 16)

        sync._validate_lora_tensor_metadata(keys, shape_for_key)
        with self.assertRaisesRegex(sync.CheckpointSyncError, "missing A or B"):
            sync._validate_lora_tensor_metadata(keys[:-1], shape_for_key)
        with self.assertRaisesRegex(sync.CheckpointSyncError, "rank mismatch"):
            sync._validate_lora_tensor_metadata(
                [
                    "base.visual.q_proj.lora_A.weight",
                    "base.visual.q_proj.lora_B.weight",
                    "base.language_model.q_proj.lora_A.weight",
                    "base.language_model.q_proj.lora_B.weight",
                ],
                lambda key: (16, 3072) if "lora_A" in key else (1024, 8),
            )

    def test_sync_pins_revision_uses_ema_adapter_and_keeps_parent_step_distinct(self):
        with test_tempdir() as temp:
            root = Path(temp)
            snapshot = write_mock_snapshot(root / "snapshot")
            observed = {}

            class FakeApi:
                def __init__(self, *, token):
                    observed["token"] = token

                def repo_info(self, *, repo_id, repo_type, revision):
                    observed["repo_info"] = (repo_id, repo_type, revision)
                    return types.SimpleNamespace(private=True, sha=REVISION_A)

            def fake_snapshot_download(**kwargs):
                observed["snapshot_kwargs"] = kwargs
                return str(snapshot)

            fake_hub = types.SimpleNamespace(HfApi=FakeApi, snapshot_download=fake_snapshot_download)
            fake_safe = types.SimpleNamespace(safe_open=FakeSafeOpen)
            with patch.dict("sys.modules", {"huggingface_hub": fake_hub, "safetensors": fake_safe}):
                manifest = sync.sync_latest_checkpoint(
                    repo_id=REPO_ID,
                    run_id=sync.DEFAULT_A100_RUN_ID,
                    token=TOKEN,
                    checkpoints_root=root / "checkpoints",
                    base_model_id=BASE_MODEL_ID,
                )

            self.assertEqual(observed["repo_info"], (REPO_ID, "model", "main"))
            self.assertEqual(observed["snapshot_kwargs"]["revision"], REVISION_A)
            self.assertEqual(observed["snapshot_kwargs"]["token"], TOKEN)
            self.assertFalse(observed["snapshot_kwargs"]["force_download"])
            cache_path = Path(observed["snapshot_kwargs"]["cache_dir"])
            self.assertEqual((cache_path.parent.name, cache_path.name), ("checkpoints", ".hf-cache"))
            self.assertEqual(manifest["repo_revision"], REVISION_A)
            self.assertEqual(manifest["optimizer_step"], 2400)
            self.assertEqual(manifest["parent_run_id"], sync.A100_PARENT_RUN_ID)
            self.assertEqual(manifest["parent_optimizer_step"], 157938)
            self.assertIn("phase-step-000002400-", manifest["phase_path"])
            checkpoints = root / "checkpoints"
            phase = checkpoints / manifest["phase_path"]
            self.assertTrue((phase / "adapter" / "adapter_model.safetensors").is_file())
            self.assertFalse((phase / "optimizer.pt").exists())
            self.assertFalse((phase / "adapter_live").exists())
            marker_text = (checkpoints / sync.ACTIVE_MANIFEST_NAME).read_text(encoding="utf-8")
            metadata_text = (phase / "download_metadata.json").read_text(encoding="utf-8")
            self.assertNotIn(TOKEN, marker_text + metadata_text)

            with patch.dict("sys.modules", {"safetensors": fake_safe}):
                active = sync.load_active_checkpoint(
                    checkpoints_root=checkpoints,
                    run_id=sync.DEFAULT_A100_RUN_ID,
                    repo_id=REPO_ID,
                    base_model_id=BASE_MODEL_ID,
                )
            self.assertEqual(active["optimizer_step"], 2400)

    def test_unrelated_repo_commit_reuses_identical_content_and_preserves_source_sha(self):
        with test_tempdir() as temp:
            root = Path(temp)
            snapshot = write_mock_snapshot(root / "snapshot")
            current_revision = [REVISION_A]

            class FakeApi:
                def __init__(self, **_kwargs):
                    pass

                def repo_info(self, **_kwargs):
                    return types.SimpleNamespace(private=True, sha=current_revision[0])

            fake_hub = types.SimpleNamespace(
                HfApi=FakeApi,
                snapshot_download=lambda **_kwargs: str(snapshot),
            )
            fake_safe = types.SimpleNamespace(safe_open=FakeSafeOpen)
            checkpoints = root / "checkpoints"
            with patch.dict("sys.modules", {"huggingface_hub": fake_hub, "safetensors": fake_safe}):
                first = sync.sync_latest_checkpoint(
                    repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                    checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                )
                current_revision[0] = REVISION_B  # unrelated upload changed repo HEAD
                second = sync.sync_latest_checkpoint(
                    repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                    checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                )
            self.assertEqual(first["phase_path"], second["phase_path"])
            self.assertEqual(second["repo_revision"], REVISION_A)  # original asset provenance
            self.assertEqual(second["verified_repo_revision"], REVISION_B)
            self.assertEqual(len(list((checkpoints / "runs" / sync.DEFAULT_A100_RUN_ID).iterdir())), 1)
            with patch.dict("sys.modules", {"safetensors": fake_safe}):
                active = sync.load_active_checkpoint(
                    checkpoints_root=checkpoints,
                    run_id=sync.DEFAULT_A100_RUN_ID,
                    repo_id=REPO_ID,
                    base_model_id=BASE_MODEL_ID,
                )
            self.assertEqual(active["repo_revision"], REVISION_A)
            self.assertEqual(active["verified_repo_revision"], REVISION_B)

    def test_modal_volume_checkpoint_stays_active_when_hf_catches_up_with_same_bytes(self):
        with test_tempdir() as temp:
            root = Path(temp)
            volume_checkpoint = write_mock_snapshot(root / "volume", state=make_state(step=2500))
            volume_checkpoint = volume_checkpoint / "runs" / sync.DEFAULT_A100_RUN_ID / "checkpoint-latest"
            fake_safe = types.SimpleNamespace(safe_open=FakeSafeOpen)
            checkpoints = root / "checkpoints"
            with patch.dict("sys.modules", {"safetensors": fake_safe}):
                volume_manifest = sync.import_local_checkpoint(
                    checkpoint_dir=volume_checkpoint,
                    run_id=sync.DEFAULT_A100_RUN_ID,
                    checkpoints_root=checkpoints,
                    base_model_id=BASE_MODEL_ID,
                    source_identity="Modal Volume openkhmer-v7-vol step2500",
                )
            self.assertEqual(volume_manifest["source_type"], "modal_volume")
            self.assertEqual(volume_manifest["optimizer_step"], 2500)
            self.assertEqual(volume_manifest["parent_optimizer_step"], 157938)
            self.assertNotIn("repo_revision", volume_manifest)

            current_revision = [REVISION_A]

            class FakeApi:
                def __init__(self, **_kwargs):
                    pass

                def repo_info(self, **_kwargs):
                    return types.SimpleNamespace(private=True, sha=current_revision[0])

            fake_hub = types.SimpleNamespace(
                HfApi=FakeApi,
                snapshot_download=lambda **_kwargs: str(volume_checkpoint.parent.parent.parent),
            )
            # The fake Hub tree has the identical state and adapter bytes.
            with patch.dict("sys.modules", {"huggingface_hub": fake_hub, "safetensors": fake_safe}):
                verified = sync.sync_latest_checkpoint(
                    repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                    checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                )
                active = sync.load_active_checkpoint(
                    checkpoints_root=checkpoints, run_id=sync.DEFAULT_A100_RUN_ID,
                    repo_id=REPO_ID, base_model_id=BASE_MODEL_ID,
                )
            self.assertEqual(verified["source_type"], "modal_volume")
            self.assertEqual(verified["source_identity"], "Modal Volume openkhmer-v7-vol step2500")
            self.assertEqual(verified["verified_hf_repo_id"], REPO_ID)
            self.assertEqual(verified["verified_hf_revision"], REVISION_A)
            self.assertNotIn("repo_revision", verified)
            self.assertEqual(active["optimizer_step"], 2500)

            next_snapshot = write_mock_snapshot(
                root / "next", state=make_state(step=2600), weight_bytes=b"next-phase-weight-bytes",
            )
            fake_hub.snapshot_download = lambda **_kwargs: str(next_snapshot)
            with patch.dict("sys.modules", {"huggingface_hub": fake_hub, "safetensors": fake_safe}):
                newer = sync.sync_latest_checkpoint(
                    repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                    checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                )
                active_after_newer_sync = sync.load_active_checkpoint(
                    checkpoints_root=checkpoints, run_id=sync.DEFAULT_A100_RUN_ID,
                    repo_id=REPO_ID, base_model_id=BASE_MODEL_ID,
                )
            self.assertEqual(newer["source_type"], "hf")
            self.assertEqual(active_after_newer_sync["optimizer_step"], 2600)
            self.assertTrue((checkpoints / volume_manifest["phase_path"]).is_dir())

    def test_older_or_same_step_different_hf_content_does_not_replace_volume_marker(self):
        with test_tempdir() as temp:
            root = Path(temp)
            volume_checkpoint = write_mock_snapshot(root / "volume", state=make_state(step=2500))
            volume_checkpoint = volume_checkpoint / "runs" / sync.DEFAULT_A100_RUN_ID / "checkpoint-latest"
            checkpoints = root / "checkpoints"
            fake_safe = types.SimpleNamespace(safe_open=FakeSafeOpen)
            with patch.dict("sys.modules", {"safetensors": fake_safe}):
                sync.import_local_checkpoint(
                    checkpoint_dir=volume_checkpoint, run_id=sync.DEFAULT_A100_RUN_ID,
                    checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                    source_identity="Modal Volume step2500",
                )
            marker = checkpoints / sync.ACTIVE_MANIFEST_NAME
            original_marker = marker.read_bytes()
            current_revision = [REVISION_A]

            class FakeApi:
                def __init__(self, **_kwargs):
                    pass

                def repo_info(self, **_kwargs):
                    return types.SimpleNamespace(private=True, sha=current_revision[0])

            fake_hub = types.SimpleNamespace(
                HfApi=FakeApi,
                snapshot_download=lambda **_kwargs: str(volume_checkpoint.parent.parent.parent),
            )
            with patch.dict("sys.modules", {"huggingface_hub": fake_hub, "safetensors": fake_safe}):
                # Lower step is rejected before any phase/marker change.
                stale = write_mock_snapshot(root / "stale", state=make_state(step=2400))
                stale_root = stale
                fake_hub.snapshot_download = lambda **_kwargs: str(stale_root)
                with self.assertRaises(sync.CheckpointOlderThanActiveError):
                    sync.sync_latest_checkpoint(
                        repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                        checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                    )
                self.assertEqual(marker.read_bytes(), original_marker)

                # Same step with different adapter bytes fails closed as a content collision.
                changed = write_mock_snapshot(
                    root / "changed", state=make_state(step=2500), weight_bytes=b"changed-weight-bytes",
                )
                fake_hub.snapshot_download = lambda **_kwargs: str(changed)
                with self.assertRaisesRegex(sync.CheckpointSyncError, "different state or adapter content"):
                    sync.sync_latest_checkpoint(
                        repo_id=REPO_ID, run_id=sync.DEFAULT_A100_RUN_ID, token=None,
                        checkpoints_root=checkpoints, base_model_id=BASE_MODEL_ID,
                    )
                self.assertEqual(marker.read_bytes(), original_marker)

    def test_invalid_parent_identity_and_incomplete_adapter_fail_closed(self):
        wrong_parent = make_state(parent_run="another-run")
        with self.assertRaisesRegex(sync.CheckpointSyncError, "lineage mismatch"):
            sync.validate_checkpoint_state(wrong_parent, sync.DEFAULT_A100_RUN_ID)
        with self.assertRaisesRegex(sync.CheckpointSyncError, "run_fingerprint"):
            sync.validate_checkpoint_state(make_state(), "not-the-configured-run")
        with test_tempdir() as temp:
            adapter = Path(temp)
            (adapter / "adapter_config.json").write_text("{}", encoding="utf-8")
            with self.assertRaisesRegex(sync.CheckpointSyncError, "adapter_model.safetensors"):
                sync._validate_adapter_dir(adapter, BASE_MODEL_ID)

    def test_explicit_model_bypasses_resolver(self):
        calls = []
        resolved = sync.resolve_adapter_override("org/manual-adapter", lambda: calls.append("called"))
        self.assertEqual(resolved, ("org/manual-adapter", "org/manual-adapter"))
        self.assertEqual(calls, [])

    def test_active_marker_run_mismatch_fails(self):
        with test_tempdir() as temp:
            root = Path(temp)
            (root / sync.ACTIVE_MANIFEST_NAME).write_text(json.dumps({
                "schema_version": 1,
                "repo_id": REPO_ID,
                "run_id": sync.A100_PARENT_RUN_ID,
            }), encoding="utf-8")
            with self.assertRaisesRegex(sync.CheckpointSyncError, "PRIVATE_RUN_ID"):
                sync.load_active_checkpoint(
                    checkpoints_root=root,
                    run_id=sync.DEFAULT_A100_RUN_ID,
                    repo_id=REPO_ID,
                    base_model_id=BASE_MODEL_ID,
                )

    def test_app_does_not_fallback_when_configured_run_has_no_active_marker(self):
        app_source = (Path(__file__).resolve().parents[1] / "app.py").read_text(encoding="utf-8")
        app_tree = ast.parse(app_source)
        self.assertNotIn("_build_or_get_ema_soup_adapter", app_source)
        self.assertIn(
            'resolve_adapter_override(\n    os.environ.get("LORA_MODEL_ID"), _resolve_default_adapter,\n)',
            app_source,
        )
        function = next(
            node for node in app_tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "ensure_latest_private_adapter"
        )
        namespace = {
            "os": types.SimpleNamespace(environ={"AUTO_PULL_LATEST_CHECKPOINT": "0"}),
            "PRIVATE_RUN_ID": sync.DEFAULT_A100_RUN_ID,
            "PRIVATE_CHECKPOINT_REPO": REPO_ID,
            "HF_PRIVATE_CHECKPOINT_TOKEN": None,
            "_CHECKPOINTS_ROOT": Path(tempfile.gettempdir()) / "no-active-checkpoint-test",
            "BASE_MODEL_ID": BASE_MODEL_ID,
            "load_active_checkpoint": lambda **_kwargs: None,
            "logger": types.SimpleNamespace(info=lambda *_a, **_k: None, warning=lambda *_a, **_k: None),
        }
        exec(compile(ast.Module(body=[function], type_ignores=[]), "<app resolver>", "exec"), namespace)
        with self.assertRaisesRegex(RuntimeError, "sync_checkpoint.py"):
            namespace["ensure_latest_private_adapter"]()

    def test_app_keeps_newer_active_modal_step_when_hf_latest_is_stale(self):
        app_tree = ast.parse((Path(__file__).resolve().parents[1] / "app.py").read_text(encoding="utf-8"))
        function = next(
            node for node in app_tree.body
            if isinstance(node, ast.FunctionDef) and node.name == "ensure_latest_private_adapter"
        )
        active = {
            "source_type": "modal_volume",
            "source_identity": "Modal Volume step2500",
            "run_id": sync.DEFAULT_A100_RUN_ID,
            "optimizer_step": 2500,
            "training_phase": "legacy-adapter-warm-start",
            "parent_run_id": sync.A100_PARENT_RUN_ID,
            "parent_optimizer_step": 157938,
            "adapter_path": "runs/2aa94c1b9590b1f3/phase-step-2500/adapter",
        }
        warnings = []

        def stale_sync(**_kwargs):
            raise sync.CheckpointOlderThanActiveError(active_step=2500, incoming_step=2400)

        namespace = {
            "os": types.SimpleNamespace(environ={"AUTO_PULL_LATEST_CHECKPOINT": "1"}),
            "PRIVATE_RUN_ID": sync.DEFAULT_A100_RUN_ID,
            "PRIVATE_CHECKPOINT_REPO": REPO_ID,
            "HF_PRIVATE_CHECKPOINT_TOKEN": None,
            "_CHECKPOINTS_ROOT": Path("checkpoints"),
            "BASE_MODEL_ID": BASE_MODEL_ID,
            "sync_latest_checkpoint": stale_sync,
            "load_active_checkpoint": lambda **_kwargs: active,
            "CheckpointOlderThanActiveError": sync.CheckpointOlderThanActiveError,
            "logger": types.SimpleNamespace(
                info=lambda *_a, **_k: None,
                warning=lambda *args, **_kwargs: warnings.append(args),
            ),
        }
        exec(compile(ast.Module(body=[function], type_ignores=[]), "<app resolver>", "exec"), namespace)
        adapter_path, display = namespace["ensure_latest_private_adapter"]()
        self.assertEqual(adapter_path, str(Path("checkpoints") / active["adapter_path"]))
        self.assertIn("step 2,500", display)
        self.assertTrue(warnings)


if __name__ == "__main__":
    unittest.main()
