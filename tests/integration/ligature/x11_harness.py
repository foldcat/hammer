#!/usr/bin/env python3
"""Compare real product rendering with ligatures enabled and disabled."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "typing"))
from x11_harness import HarnessFailure, X11, open_untitled, wait_for_exit


def run_case(x11: X11, binary: Path, label: str, sandbox: Path, timeout: float) -> bytes:
    process: subprocess.Popen[bytes] | None = None
    log_path = sandbox / f"hammer-{label}.log"
    try:
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / f"state-{label}")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            window = x11.find_window(timeout)
            x11.lib.XMapRaised(x11.display, window)
            x11.lib.XSetInputFocus(x11.display, window, 1, 0)
            x11.lib.XSync(x11.display, 0)
            time.sleep(0.3)
            open_untitled(x11, window, log_path, timeout)
            initial = x11.pixels(window)
            x11.tap(ord("f"))
            x11.tap(ord("i"))
            time.sleep(0.4)
            rendered = x11.pixels(window)
            if rendered == initial:
                raise HarnessFailure(f"{label}: typing fi did not render text; log: {log_path}")

            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            if x11.pixels(window) != initial:
                raise HarnessFailure(f"{label}: undo did not restore the initial pixels; log: {log_path}")
            x11.quit()
            wait_for_exit(process, timeout, log_path)
            process = None
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    expected_flag = "ligatures=true" if label == "enabled" else "ligatures=false"
    if expected_flag not in log_text or "FixtureLigature.ttf" not in log_text:
        raise HarnessFailure(f"{label}: product did not use its staged ligature config; log: {log_path}")
    print(f"PASS: {label} product rendered fi and restored the initial document ({rendered.hex()})")
    return rendered


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--enabled", required=True, type=Path)
    parser.add_argument("--disabled", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    enabled = args.enabled.resolve()
    disabled = args.disabled.resolve()
    if not enabled.is_file() or not disabled.is_file():
        parser.error("--enabled and --disabled must name Hammer executables")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m05-09-ligature-"))
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        enabled_pixels = run_case(x11, enabled, "enabled", sandbox, args.timeout)
        disabled_pixels = run_case(x11, disabled, "disabled", sandbox, args.timeout)
        if enabled_pixels == disabled_pixels:
            raise HarnessFailure(f"ligatures=true and ligatures=false produced identical pixels; logs: {sandbox}")
        print("PASS: product ligature configuration changes native glyph rendering")
        succeeded = True
        return 0
    except (HarnessFailure, OSError) as error:
        print(f"FAIL: {error}; preserved sandbox: {sandbox}", file=sys.stderr)
        return 1
    finally:
        if x11 is not None:
            x11.close()
        if succeeded:
            shutil.rmtree(sandbox)


if __name__ == "__main__":
    raise SystemExit(main())
