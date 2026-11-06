#!/usr/bin/env python3
"""Fail on environment files or common credential material in Git content."""

from __future__ import annotations

import re
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
PATTERNS = {
    "private key block": re.compile(r"-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    "Google API key": re.compile(r"AIza[0-9A-Za-z_-]{30,60}"),
    "Resend API key": re.compile(r"\bre_[0-9A-Za-z]{20,}\b"),
    "Hugging Face token": re.compile(r"\bhf_[0-9A-Za-z]{30,}\b"),
    "service-account private_key field": re.compile(r'"private_key"\s*:\s*"'),
}


def candidate_files() -> list[str]:
    output = subprocess.check_output(
        ["git", "ls-files", "--cached", "--others", "--exclude-standard"],
        cwd=ROOT,
        text=True,
    )
    return [line.strip() for line in output.splitlines() if line.strip()]


def main() -> int:
    failures: list[str] = []
    files = candidate_files()
    for relative in files:
        path = ROOT / relative
        name = path.name
        if name.startswith(".env") and not name.endswith(".example"):
            failures.append(f"environment file: {relative}")
            continue
        if not path.is_file() or path.stat().st_size > 2_000_000:
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except (UnicodeDecodeError, OSError):
            continue
        for line_number, line in enumerate(text.splitlines(), start=1):
            for label, pattern in PATTERNS.items():
                if pattern.search(line):
                    failures.append(f"{label}: {relative}:{line_number}")

    if failures:
        print("Potential secrets found (values are intentionally hidden):")
        for failure in failures:
            print(f"  - {failure}")
        return 1
    print(f"Secret scan passed for {len(files)} tracked or untracked non-ignored files.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
