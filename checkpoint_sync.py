"""Pinned, non-destructive sync of one OpenKhmer checkpoint phase."""
from __future__ import annotations

import json
import os
import re
import shutil
import tempfile
from pathlib import Path, PurePosixPath
from typing import Any


DEFAULT_A100_RUN_ID = "2aa94c1b9590b1f3"
A100_PARENT_RUN_ID = "d84cd55f108195b1"
A100_PARENT_STEP = 157_938
A100_MIN_PHASE_STEP = 2_400
ACTIVE_MANIFEST_NAME = "active_checkpoint.json"


class CheckpointSyncError(RuntimeError):
    """Checkpoint metadata, download, or activation is unsafe to use."""


class CheckpointOlderThanActiveError(CheckpointSyncError):
    def __init__(self, active_step: int, incoming_step: int):
        self.active_step = active_step
        self.incoming_step = incoming_step
        super().__init__(
            f"HF checkpoint step {incoming_step} is older than active step {active_step}; "
            "the active marker was preserved."
        )


def resolve_adapter_override(explicit_model_id: str | None, resolver):
    """An explicit model override bypasses all checkpoint discovery and sync."""
    if explicit_model_id:
        return str(explicit_model_id), str(explicit_model_id)
    return resolver()


def _safe_run_id(run_id: str) -> str:
    if not isinstance(run_id, str) or not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", run_id):
        raise CheckpointSyncError(f"Invalid PRIVATE_RUN_ID {run_id!r}.")
    return run_id


def _source_lineage(state: dict[str, Any]) -> tuple[str | None, int | None]:
    source = state.get("warm_start_source")
    if source is None:
        return None, None
    if not isinstance(source, dict):
        raise CheckpointSyncError("Checkpoint warm_start_source metadata is not an object.")
    source_run_id = source.get("source_run_id") or source.get("run_id")
    try:
        source_step = int(source["optimizer_step"])
    except (KeyError, TypeError, ValueError) as exc:
        raise CheckpointSyncError("Checkpoint parent optimizer_step is missing or invalid.") from exc
    if not isinstance(source_run_id, str) or not source_run_id or source_step <= 0:
        raise CheckpointSyncError("Checkpoint parent run ID or optimizer step is invalid.")
    return source_run_id, source_step


def validate_checkpoint_state(state: dict[str, Any], run_id: str) -> dict[str, Any]:
    """Check state identity and retain phase and warm-start lineage separately."""
    run_id = _safe_run_id(run_id)
    if not isinstance(state, dict):
        raise CheckpointSyncError("Checkpoint state.json must contain an object.")
    fingerprint = state.get("run_fingerprint")
    if not isinstance(fingerprint, str) or not fingerprint.startswith(run_id):
        raise CheckpointSyncError(
            f"Checkpoint run_fingerprint does not identify configured run {run_id!r}."
        )
    if state.get("run_id") not in (None, run_id):
        raise CheckpointSyncError(
            f"Checkpoint state run_id {state.get('run_id')!r} does not match {run_id!r}."
        )
    try:
        step = int(state["optimizer_step"])
    except (KeyError, TypeError, ValueError) as exc:
        raise CheckpointSyncError("Checkpoint optimizer_step is missing or invalid.") from exc
    if step <= 0:
        raise CheckpointSyncError(f"Checkpoint optimizer_step {step} is not positive.")

    parent_run_id, parent_step = _source_lineage(state)
    training_phase = state.get("training_phase")
    if run_id == DEFAULT_A100_RUN_ID:
        if step < A100_MIN_PHASE_STEP:
            raise CheckpointSyncError(
                f"A100 phase checkpoint is at step {step}; expected at least {A100_MIN_PHASE_STEP}."
            )
        if training_phase != "legacy-adapter-warm-start":
            raise CheckpointSyncError(
                f"A100 checkpoint training_phase is {training_phase!r}; expected 'legacy-adapter-warm-start'."
            )
        if int(state.get("checkpoint_schema_version", -1)) < 2:
            raise CheckpointSyncError("A100 checkpoint lacks the live/EMA schema required for its EMA export.")
        if state.get("ema_adapter_path") != "adapter":
            raise CheckpointSyncError("A100 inference weights must come from the checkpoint's EMA adapter/ export.")
        if int(state.get("world_size", -1)) != 1:
            raise CheckpointSyncError("A100 phase checkpoint must identify its single-GPU run.")
        if parent_run_id != A100_PARENT_RUN_ID or parent_step != A100_PARENT_STEP:
            raise CheckpointSyncError(
                "A100 phase lineage mismatch: expected parent run "
                f"{A100_PARENT_RUN_ID} at optimizer step {A100_PARENT_STEP}, got "
                f"{parent_run_id!r} at {parent_step!r}."
            )
        expected_parent_path = f"runs/{A100_PARENT_RUN_ID}/checkpoint-latest"
        source = state["warm_start_source"]
        if source.get("repo_path") != expected_parent_path:
            raise CheckpointSyncError(
                f"A100 warm-start parent path {source.get('repo_path')!r} does not match {expected_parent_path!r}."
            )
    elif state.get("warm_start_source") is not None and (parent_run_id is None or parent_step is None):
        raise CheckpointSyncError("Configured checkpoint has incomplete parent lineage metadata.")

    return {
        "run_id": run_id,
        "optimizer_step": step,
        "training_phase": training_phase,
        "parent_run_id": parent_run_id,
        "parent_optimizer_step": parent_step,
    }


def _validate_lora_tensor_metadata(keys: list[str], shape_for_key) -> None:
    """Check complete A/B pairs, rank dimensions, and both vision/language roots."""
    if not keys:
        raise CheckpointSyncError("Adapter safetensors file contains no tensors.")
    pairs: dict[tuple[str, str | None], dict[str, tuple[int, ...]]] = {}
    lora_key = re.compile(
        r"^(?P<module>.*)\.lora_(?P<side>A|B)(?:\.(?P<adapter>[^.]+))?\.weight$"
    )
    has_visual = False
    has_language = False
    for key in keys:
        has_visual |= re.search(r"(?:^|[._])(?:visual|vision)(?:[._]|$)", key, re.IGNORECASE) is not None
        has_language |= re.search(r"(?:^|[._])language_model(?:[._]|$)", key, re.IGNORECASE) is not None
        match = lora_key.match(key)
        if not match:
            continue
        try:
            shape = tuple(int(dim) for dim in shape_for_key(key))
        except Exception as exc:
            raise CheckpointSyncError(f"Cannot inspect adapter tensor shape for {key!r}.") from exc
        if len(shape) < 2 or any(dim <= 0 for dim in shape):
            raise CheckpointSyncError(f"Adapter tensor {key!r} has an invalid LoRA shape {shape!r}.")
        pair_id = (match.group("module"), match.group("adapter"))
        side = match.group("side")
        if side in pairs.setdefault(pair_id, {}):
            raise CheckpointSyncError(f"Adapter has duplicate LoRA {side} weights for {pair_id!r}.")
        pairs[pair_id][side] = shape
    if not has_visual or not has_language:
        raise CheckpointSyncError(
            "Adapter weights must include both visual/vision and language_model LoRA roots."
        )
    if not pairs:
        raise CheckpointSyncError("Adapter safetensors file contains no recognizable LoRA A/B weights.")
    for pair_id, sides in pairs.items():
        if set(sides) != {"A", "B"}:
            raise CheckpointSyncError(f"Adapter LoRA pair {pair_id!r} is missing A or B weights.")
        shape_a = sides["A"]
        shape_b = sides["B"]
        # PEFT linear and convolution LoRA layouts put rank first in A and
        # second in B; inspect safetensors headers, never tensor bodies.
        if shape_a[0] != shape_b[1]:
            raise CheckpointSyncError(
                f"Adapter LoRA A/B rank mismatch for {pair_id!r}: "
                f"A shape {shape_a!r}, B shape {shape_b!r}."
            )


def _validate_adapter_dir(adapter_dir: Path, base_model_id: str) -> dict[str, Any]:
    config_path = adapter_dir / "adapter_config.json"
    weights_path = adapter_dir / "adapter_model.safetensors"
    if not config_path.is_file() or config_path.stat().st_size == 0:
        raise CheckpointSyncError(f"Adapter is incomplete: missing {config_path.name}.")
    if not weights_path.is_file() or weights_path.stat().st_size <= 8:
        raise CheckpointSyncError(f"Adapter is incomplete: missing or empty {weights_path.name}.")
    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CheckpointSyncError("Adapter adapter_config.json cannot be read as JSON.") from exc
    if not isinstance(config, dict) or str(config.get("peft_type", "")).upper() != "LORA":
        raise CheckpointSyncError("Checkpoint adapter_config.json does not describe a LoRA adapter.")
    if config.get("base_model_name_or_path") != base_model_id:
        raise CheckpointSyncError(
            "Checkpoint adapter base model mismatch: "
            f"{config.get('base_model_name_or_path')!r} != {base_model_id!r}."
        )
    if not config.get("target_modules"):
        raise CheckpointSyncError("Adapter config has no target_modules.")
    try:
        if int(config.get("r", 0)) <= 0 or float(config.get("lora_alpha", 0)) <= 0:
            raise CheckpointSyncError("Adapter LoRA rank/alpha must be positive.")
    except (TypeError, ValueError) as exc:
        raise CheckpointSyncError("Adapter LoRA rank/alpha are invalid.") from exc
    try:
        from safetensors import safe_open

        with safe_open(str(weights_path), framework="pt", device="cpu") as tensors:
            keys = list(tensors.keys())
            _validate_lora_tensor_metadata(
                keys, lambda key: tensors.get_slice(key).get_shape(),
            )
    except CheckpointSyncError:
        raise
    except Exception as exc:
        raise CheckpointSyncError("Adapter safetensors header is invalid or unreadable.") from exc
    return config


def _sha256(path: Path) -> str:
    import hashlib

    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def _hash_tree(directory: Path) -> dict[str, str]:
    result = {
        path.relative_to(directory).as_posix(): _sha256(path)
        for path in sorted(directory.rglob("*"))
        if path.is_file()
    }
    if not result:
        raise CheckpointSyncError(f"Adapter directory {directory} contains no files.")
    return result


def _content_identity(state_sha256: str, adapter_files_sha256: dict[str, str]) -> str:
    import hashlib

    material = json.dumps(
        {"state_sha256": state_sha256, "adapter_files_sha256": adapter_files_sha256},
        sort_keys=True, separators=(",", ":"),
    ).encode("utf-8")
    return hashlib.sha256(material).hexdigest()


def _write_json_atomic(path: Path, payload: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", suffix=".tmp", dir=str(path.parent))
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(payload, stream, indent=2, sort_keys=True)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temp_path, path)
    except BaseException:
        try:
            temp_path.unlink(missing_ok=True)
        except OSError:
            pass
        raise


def _ensure_within_checkpoints(path: Path, checkpoints_root: Path) -> Path:
    root = Path(checkpoints_root).resolve()
    resolved = Path(path).resolve()
    try:
        resolved.relative_to(root)
    except ValueError as exc:
        raise CheckpointSyncError(
            f"Refusing filesystem operation outside checkpoints directory: {resolved}."
        ) from exc
    return resolved


def _remove_stage(stage_dir: Path, checkpoints_root: Path) -> None:
    if stage_dir.exists():
        _ensure_within_checkpoints(stage_dir, checkpoints_root)
        shutil.rmtree(stage_dir)


def _phase_paths(checkpoints_root: Path, run_id: str, step: int,
                 content_sha256: str) -> tuple[Path, Path]:
    root = checkpoints_root.resolve()
    phase_dir = root / "runs" / _safe_run_id(run_id) / (
        f"phase-step-{int(step):09d}-{content_sha256[:16]}"
    )
    try:
        phase_dir.resolve().relative_to(root)
    except ValueError as exc:
        raise CheckpointSyncError("Checkpoint phase path escapes the checkpoints directory.") from exc
    return phase_dir, phase_dir / "adapter"


def _read_local_phase(
    phase_dir: Path, adapter_dir: Path, *, repo_id: str | None, source_type: str | None,
    source_identity: str | None,
    state_info: dict[str, Any], base_model_id: str,
    expected_state_sha256: str | None = None,
    expected_adapter_files_sha256: dict[str, str] | None = None,
    expected_content_sha256: str | None = None,
) -> dict[str, Any]:
    state_path = phase_dir / "state.json"
    meta_path = phase_dir / "download_metadata.json"
    if not state_path.is_file() or not meta_path.is_file():
        raise CheckpointSyncError(
            f"Existing phase directory {phase_dir} is incomplete; it was left untouched."
        )
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
        local_meta = json.loads(meta_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CheckpointSyncError(f"Existing phase metadata is unreadable: {phase_dir}.") from exc
    local_info = validate_checkpoint_state(state, state_info["run_id"])
    local_state_sha256 = _sha256(state_path)
    local_adapter_hashes = _hash_tree(adapter_dir)
    local_content_sha256 = _content_identity(local_state_sha256, local_adapter_hashes)
    local_source_type = local_meta.get("source_type", "hf")
    if (local_source_type not in {"hf", "modal_volume"}
            or (source_type is not None and local_source_type != source_type)
            or (repo_id is not None and local_meta.get("repo_id") != repo_id)
            or (local_source_type == "hf" and (not local_meta.get("repo_id") or not local_meta.get("repo_revision")))
            or (local_source_type == "modal_volume" and not local_meta.get("source_identity"))
            or (source_identity is not None and local_meta.get("source_identity") != source_identity)
            or local_meta.get("run_id") != local_info["run_id"]
            or int(local_meta.get("optimizer_step", -1)) != local_info["optimizer_step"]
            or local_info != state_info
            or local_meta.get("state_sha256") != local_state_sha256
            or local_meta.get("adapter_files_sha256") != local_adapter_hashes
            or local_meta.get("content_sha256") != local_content_sha256
            or (expected_state_sha256 is not None and expected_state_sha256 != local_state_sha256)
            or (expected_adapter_files_sha256 is not None
                and expected_adapter_files_sha256 != local_adapter_hashes)
            or (expected_content_sha256 is not None
                and expected_content_sha256 != local_content_sha256)):
        raise CheckpointSyncError(
            f"Existing phase directory {phase_dir} conflicts with the pinned checkpoint; it was left untouched."
        )
    _validate_adapter_dir(adapter_dir, base_model_id)
    return local_meta


def _manifest_for(checkpoints_root: Path, phase_dir: Path, adapter_dir: Path,
                  state_info: dict[str, Any], metadata: dict[str, Any],
                  verified_revision: str | None = None,
                  verified_hf_repo_id: str | None = None) -> dict[str, Any]:
    source_type = metadata.get("source_type", "hf")
    manifest = {
        "schema_version": 1,
        "source_type": source_type,
        "run_id": state_info["run_id"],
        "optimizer_step": state_info["optimizer_step"],
        "training_phase": state_info["training_phase"],
        "parent_run_id": state_info["parent_run_id"],
        "parent_optimizer_step": state_info["parent_optimizer_step"],
        "phase_path": phase_dir.relative_to(checkpoints_root.resolve()).as_posix(),
        "adapter_path": adapter_dir.relative_to(checkpoints_root.resolve()).as_posix(),
        "adapter_sha256": metadata["adapter_sha256"],
        "adapter_files_sha256": metadata["adapter_files_sha256"],
        "state_sha256": metadata["state_sha256"],
        "content_sha256": metadata["content_sha256"],
    }
    if source_type == "hf":
        manifest.update({
            "repo_id": metadata["repo_id"],
            "repo_revision": metadata["repo_revision"],
        })
        if verified_hf_repo_id:
            manifest["verified_hf_repo_id"] = verified_hf_repo_id
            manifest["verified_hf_revision"] = verified_revision or metadata["repo_revision"]
        if verified_hf_repo_id == metadata["repo_id"]:
            manifest["verified_repo_revision"] = verified_revision or metadata["repo_revision"]
    else:
        manifest["source_identity"] = metadata["source_identity"]
        if verified_hf_repo_id:
            manifest["verified_hf_repo_id"] = verified_hf_repo_id
            manifest["verified_hf_revision"] = verified_revision
    return manifest


def _activate_manifest(checkpoints_root: Path, manifest: dict[str, Any], base_model_id: str) -> None:
    """Atomically activate; preserve same-run state when a stale source is offered."""
    marker = Path(checkpoints_root) / ACTIVE_MANIFEST_NAME
    if marker.is_file():
        try:
            existing = json.loads(marker.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise CheckpointSyncError("Existing active checkpoint marker is unreadable; it was left untouched.") from exc
        if not isinstance(existing, dict):
            raise CheckpointSyncError("Existing active checkpoint marker is invalid; it was left untouched.")
        if existing.get("run_id") == manifest.get("run_id"):
            active = load_active_checkpoint(
                checkpoints_root=checkpoints_root,
                run_id=str(existing.get("run_id")),
                repo_id=str(existing.get("repo_id") or existing.get("verified_hf_repo_id") or ""),
                base_model_id=base_model_id,
            )
            if active is not None:
                active_step = int(active["optimizer_step"])
                incoming_step = int(manifest["optimizer_step"])
                if active_step > incoming_step:
                    raise CheckpointOlderThanActiveError(active_step, incoming_step)
                if (active_step == incoming_step
                        and active.get("content_sha256") != manifest.get("content_sha256")):
                    raise CheckpointSyncError(
                        f"Step {incoming_step} already has different active checkpoint content; "
                        "refusing to replace the active marker."
                    )
    _write_json_atomic(marker, manifest)


def sync_latest_checkpoint(
    *, repo_id: str, run_id: str, token: str | None, checkpoints_root: Path,
    base_model_id: str,
) -> dict[str, Any]:
    """Download one latest pointer at a pinned repo SHA and atomically activate it."""
    from huggingface_hub import HfApi, snapshot_download

    run_id = _safe_run_id(run_id)
    checkpoints_root = Path(checkpoints_root).resolve()
    api = HfApi(token=token or False)
    try:
        repo = api.repo_info(repo_id=repo_id, repo_type="model", revision="main")
    except Exception as exc:
        raise CheckpointSyncError(
            f"Could not inspect private checkpoint repository {repo_id!r} ({type(exc).__name__}); "
            "check the repository name and HF_PRIVATE_CHECKPOINT_TOKEN read access."
        ) from None
    if getattr(repo, "private", None) is not True:
        raise CheckpointSyncError(f"Checkpoint repository {repo_id!r} is not private.")
    revision = getattr(repo, "sha", None)
    if not isinstance(revision, str) or not revision:
        raise CheckpointSyncError("Hugging Face did not return an immutable repository revision.")

    prefix = f"runs/{run_id}/checkpoint-latest"
    checkpoints_root.mkdir(parents=True, exist_ok=True)
    try:
        snapshot_root = Path(snapshot_download(
            repo_id=repo_id,
            repo_type="model",
            revision=revision,
            allow_patterns=[f"{prefix}/state.json", f"{prefix}/adapter/*"],
            token=token or False,
            cache_dir=str(checkpoints_root / ".hf-cache"),
            force_download=False,
        ))
    except Exception as exc:
        raise CheckpointSyncError(
            f"Could not download run {run_id!r} at pinned revision {revision} "
            f"({type(exc).__name__}); check checkpoint availability and token access."
        ) from None
    remote_phase = snapshot_root.joinpath(*PurePosixPath(prefix).parts)
    state_path = remote_phase / "state.json"
    remote_adapter = remote_phase / "adapter"
    if not state_path.is_file() or not remote_adapter.is_dir():
        raise CheckpointSyncError(
            f"Pinned revision {revision} has no complete checkpoint at {prefix!r}."
        )
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CheckpointSyncError("Pinned checkpoint state.json is unreadable.") from exc
    state_info = validate_checkpoint_state(state, run_id)
    _validate_adapter_dir(remote_adapter, base_model_id)
    remote_state_sha256 = _sha256(state_path)
    remote_adapter_hashes = _hash_tree(remote_adapter)
    content_sha256 = _content_identity(remote_state_sha256, remote_adapter_hashes)
    existing_marker_path = checkpoints_root / ACTIVE_MANIFEST_NAME
    if existing_marker_path.is_file():
        try:
            existing_marker = json.loads(existing_marker_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as exc:
            raise CheckpointSyncError("Existing active checkpoint marker is unreadable; it was left untouched.") from exc
        if isinstance(existing_marker, dict) and existing_marker.get("run_id") == run_id:
            active = load_active_checkpoint(
                checkpoints_root=checkpoints_root,
                run_id=run_id,
                repo_id=str(existing_marker.get("repo_id", repo_id)),
                base_model_id=base_model_id,
            )
            if active is not None:
                active_step = int(active["optimizer_step"])
                if active_step > state_info["optimizer_step"]:
                    raise CheckpointOlderThanActiveError(active_step, state_info["optimizer_step"])
                if (active_step == state_info["optimizer_step"]
                        and active.get("content_sha256") != content_sha256):
                    raise CheckpointSyncError(
                        f"HF checkpoint step {active_step} has different state or adapter content; "
                        "refusing to replace the active marker."
                    )
    phase_dir, adapter_dir = _phase_paths(
        checkpoints_root, run_id, state_info["optimizer_step"], content_sha256,
    )

    if phase_dir.exists():
        local_meta = _read_local_phase(
            phase_dir, adapter_dir, repo_id=None, source_type=None, source_identity=None,
            state_info=state_info, base_model_id=base_model_id,
            expected_state_sha256=remote_state_sha256,
            expected_adapter_files_sha256=remote_adapter_hashes,
            expected_content_sha256=content_sha256,
        )
    else:
        phase_dir.parent.mkdir(parents=True, exist_ok=True)
        stage_dir = Path(tempfile.mkdtemp(prefix=f".{phase_dir.name}.stage-", dir=str(phase_dir.parent)))
        try:
            shutil.copytree(remote_adapter, stage_dir / "adapter")
            shutil.copy2(state_path, stage_dir / "state.json")
            staged_adapter = stage_dir / "adapter"
            metadata = {
                "source_type": "hf",
                "repo_id": repo_id,
                "repo_revision": revision,
                "run_id": run_id,
                "optimizer_step": state_info["optimizer_step"],
                "adapter_sha256": _sha256(staged_adapter / "adapter_model.safetensors"),
                "adapter_files_sha256": _hash_tree(staged_adapter),
                "state_sha256": _sha256(stage_dir / "state.json"),
            }
            metadata["content_sha256"] = _content_identity(
                metadata["state_sha256"], metadata["adapter_files_sha256"],
            )
            if metadata["content_sha256"] != content_sha256:
                raise CheckpointSyncError("Staged checkpoint content differs from the pinned HF snapshot.")
            (stage_dir / "download_metadata.json").write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            _validate_adapter_dir(staged_adapter, base_model_id)
            _ensure_within_checkpoints(stage_dir, checkpoints_root)
            _ensure_within_checkpoints(phase_dir, checkpoints_root)
            if phase_dir.exists():
                raise CheckpointSyncError(f"Checkpoint phase appeared during sync; refusing overwrite: {phase_dir}.")
            os.rename(stage_dir, phase_dir)
            local_meta = metadata
        except BaseException:
            _remove_stage(stage_dir, checkpoints_root)
            raise

    manifest = _manifest_for(
        checkpoints_root, phase_dir, adapter_dir, state_info, local_meta,
        verified_revision=revision, verified_hf_repo_id=repo_id,
    )
    _activate_manifest(checkpoints_root, manifest, base_model_id)
    return manifest


def load_active_checkpoint(
    *, checkpoints_root: Path, run_id: str, repo_id: str, base_model_id: str,
) -> dict[str, Any] | None:
    """Validate the explicitly activated local phase; never rank steps across runs."""
    checkpoints_root = Path(checkpoints_root).resolve()
    marker = checkpoints_root / ACTIVE_MANIFEST_NAME
    if not marker.exists():
        return None
    try:
        manifest = json.loads(marker.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CheckpointSyncError(f"Active checkpoint marker {marker} is unreadable.") from exc
    if not isinstance(manifest, dict) or manifest.get("schema_version") != 1:
        raise CheckpointSyncError(f"Active checkpoint marker {marker} has an unsupported schema.")
    configured_run = _safe_run_id(run_id)
    source_type = manifest.get("source_type", "hf")
    if source_type not in {"hf", "modal_volume"}:
        raise CheckpointSyncError(f"Active checkpoint source_type {source_type!r} is unsupported.")
    if source_type == "hf":
        recognized_repos = {manifest.get("repo_id"), manifest.get("verified_hf_repo_id")}
        if repo_id not in recognized_repos:
            raise CheckpointSyncError(
                f"Active checkpoint repository {manifest.get('repo_id')!r} does not match "
                f"PRIVATE_CHECKPOINT_REPO {repo_id!r}."
            )
    if source_type == "modal_volume" and not manifest.get("source_identity"):
        raise CheckpointSyncError("Active Modal Volume checkpoint is missing source_identity.")
    if (source_type == "modal_volume" and manifest.get("verified_hf_repo_id")
            and manifest.get("verified_hf_repo_id") != repo_id):
        raise CheckpointSyncError(
            "Active Modal checkpoint was last verified against a different PRIVATE_CHECKPOINT_REPO."
        )
    if manifest.get("run_id") != configured_run:
        raise CheckpointSyncError(
            f"Active checkpoint belongs to run {manifest.get('run_id')!r}, but PRIVATE_RUN_ID is "
            f"{configured_run!r}. Run the sync entrypoint for the configured run."
        )
    rel_phase = PurePosixPath(str(manifest.get("phase_path", "")))
    rel_adapter = PurePosixPath(str(manifest.get("adapter_path", "")))
    if rel_phase.is_absolute() or rel_adapter.is_absolute() or ".." in rel_phase.parts or ".." in rel_adapter.parts:
        raise CheckpointSyncError("Active checkpoint marker contains an unsafe local path.")
    phase_dir = checkpoints_root.joinpath(*rel_phase.parts)
    adapter_dir = checkpoints_root.joinpath(*rel_adapter.parts)
    try:
        phase_dir.resolve().relative_to(checkpoints_root)
        adapter_dir.resolve().relative_to(checkpoints_root)
    except ValueError as exc:
        raise CheckpointSyncError("Active checkpoint paths escape the checkpoints directory.") from exc
    metadata = _read_local_phase(
        phase_dir, adapter_dir,
        repo_id=manifest.get("repo_id") if source_type == "hf" else None,
        source_type=source_type,
        source_identity=manifest.get("source_identity") if source_type == "modal_volume" else None,
        state_info={
            "run_id": configured_run,
            "optimizer_step": int(manifest.get("optimizer_step", -1)),
            "training_phase": manifest.get("training_phase"),
            "parent_run_id": manifest.get("parent_run_id"),
            "parent_optimizer_step": manifest.get("parent_optimizer_step"),
        },
        base_model_id=base_model_id,
        expected_state_sha256=str(manifest.get("state_sha256", "")),
        expected_adapter_files_sha256=manifest.get("adapter_files_sha256"),
        expected_content_sha256=str(manifest.get("content_sha256", "")),
    )
    verified_hf_repo = manifest.get("verified_hf_repo_id")
    verified_hf_revision = manifest.get("verified_hf_revision")
    if bool(verified_hf_repo) != bool(verified_hf_revision):
        raise CheckpointSyncError("Active checkpoint has incomplete verified-HF provenance.")
    if source_type == "hf":
        origin_provenance = (
            manifest.get("repo_id") == repo_id
            and manifest.get("repo_revision") == metadata.get("repo_revision")
        )
        current_verification = (
            verified_hf_repo == repo_id and bool(verified_hf_revision)
        )
        provenance_valid = origin_provenance or current_verification
    else:
        provenance_valid = (
            not manifest.get("repo_revision")
            and not manifest.get("verified_repo_revision")
            and manifest.get("source_identity") == metadata.get("source_identity")
            and (not verified_hf_repo or verified_hf_repo == repo_id)
        )
    if not provenance_valid or manifest.get("adapter_sha256") != metadata.get("adapter_sha256"):
        raise CheckpointSyncError("Active checkpoint marker provenance or adapter checksum is invalid.")
    return manifest


def import_local_checkpoint(
    *, checkpoint_dir: Path, run_id: str, checkpoints_root: Path,
    base_model_id: str, source_identity: str | None = None,
) -> dict[str, Any]:
    """Activate a locally copied Volume checkpoint without claiming HF provenance."""
    run_id = _safe_run_id(run_id)
    checkpoint_dir = Path(checkpoint_dir).resolve()
    state_path = checkpoint_dir / "state.json"
    source_adapter = checkpoint_dir / "adapter"
    if not state_path.is_file() or not source_adapter.is_dir():
        raise CheckpointSyncError(
            f"Local checkpoint {checkpoint_dir} must contain state.json and adapter/."
        )
    try:
        state = json.loads(state_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        raise CheckpointSyncError("Local checkpoint state.json is unreadable.") from exc
    state_info = validate_checkpoint_state(state, run_id)
    _validate_adapter_dir(source_adapter, base_model_id)
    if source_identity is None:
        source_identity = (
            f"modal-volume:{run_id}:step{state_info['optimizer_step']}"
        )
    if not isinstance(source_identity, str) or not source_identity.strip():
        raise CheckpointSyncError("Local checkpoint source_identity must be a nonempty label.")

    checkpoints_root = Path(checkpoints_root).resolve()
    checkpoints_root.mkdir(parents=True, exist_ok=True)
    state_sha256 = _sha256(state_path)
    adapter_hashes = _hash_tree(source_adapter)
    content_sha256 = _content_identity(state_sha256, adapter_hashes)
    phase_dir, adapter_dir = _phase_paths(
        checkpoints_root, run_id, state_info["optimizer_step"], content_sha256,
    )
    if phase_dir.exists():
        metadata = _read_local_phase(
            phase_dir, adapter_dir, repo_id=None, source_type=None,
            source_identity=None, state_info=state_info,
            base_model_id=base_model_id, expected_state_sha256=state_sha256,
            expected_adapter_files_sha256=adapter_hashes,
            expected_content_sha256=content_sha256,
        )
    else:
        phase_dir.parent.mkdir(parents=True, exist_ok=True)
        stage_dir = Path(tempfile.mkdtemp(prefix=f".{phase_dir.name}.stage-", dir=str(phase_dir.parent)))
        try:
            shutil.copytree(source_adapter, stage_dir / "adapter")
            shutil.copy2(state_path, stage_dir / "state.json")
            staged_adapter = stage_dir / "adapter"
            metadata = {
                "source_type": "modal_volume",
                "source_identity": source_identity,
                "repo_id": None,
                "run_id": run_id,
                "optimizer_step": state_info["optimizer_step"],
                "adapter_sha256": _sha256(staged_adapter / "adapter_model.safetensors"),
                "adapter_files_sha256": _hash_tree(staged_adapter),
                "state_sha256": _sha256(stage_dir / "state.json"),
            }
            metadata["content_sha256"] = _content_identity(
                metadata["state_sha256"], metadata["adapter_files_sha256"],
            )
            if metadata["content_sha256"] != content_sha256:
                raise CheckpointSyncError("Staged local checkpoint content changed during import.")
            (stage_dir / "download_metadata.json").write_text(
                json.dumps(metadata, indent=2, sort_keys=True) + "\n", encoding="utf-8"
            )
            _validate_adapter_dir(staged_adapter, base_model_id)
            _ensure_within_checkpoints(stage_dir, checkpoints_root)
            _ensure_within_checkpoints(phase_dir, checkpoints_root)
            if phase_dir.exists():
                raise CheckpointSyncError(f"Checkpoint phase appeared during import; refusing overwrite: {phase_dir}.")
            os.rename(stage_dir, phase_dir)
        except BaseException:
            _remove_stage(stage_dir, checkpoints_root)
            raise

    manifest = _manifest_for(checkpoints_root, phase_dir, adapter_dir, state_info, metadata)
    _activate_manifest(checkpoints_root, manifest, base_model_id)
    return manifest
