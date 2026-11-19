#!/usr/bin/env python3
"""Run process tests with an external timeout and owned-process cleanup."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import signal
import subprocess
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--repo", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=30.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 120.0:
        parser.error("--timeout must be between 1 and 120 seconds")
    repo = args.repo.resolve()
    helper = repo / "build" / "process_test_helper"
    if os.name == "nt":
        helper = helper.with_suffix(".exe")
    if not helper.is_file():
        parser.error(f"purpose-built helper is missing: {helper}")

    command = [
        "odin",
        "test",
        str(repo / "tests" / "unit" / "process"),
        "-vet",
        f"-collection:hammer={repo / 'src'}",
        "-define:ODIN_TEST_THREADS=1",
    ]
    process = subprocess.Popen(
        command,
        cwd=repo,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        start_new_session=os.name == "posix",
    )
    try:
        output, _ = process.communicate(timeout=args.timeout)
    except subprocess.TimeoutExpired:
        if os.name == "posix":
            os.killpg(process.pid, signal.SIGKILL)
        else:
            process.kill()
        output, _ = process.communicate()
        sys.stdout.write(output.decode("utf-8", errors="replace"))
        print(f"process tests timed out after {args.timeout:g} seconds", file=sys.stderr)
        return 1
    sys.stdout.write(output.decode("utf-8", errors="replace"))
    return process.returncode


if __name__ == "__main__":
    raise SystemExit(main())
