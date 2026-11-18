#!/usr/bin/env python3
"""Real X11 column/window dragging smoke test for M07.01."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402


def wait_for_layout_line(log_path: Path, pattern: str, timeout: float, occurrence: int = 1) -> re.Match[str]:
    deadline = time.monotonic() + timeout
    compiled = re.compile(pattern)
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        matches = list(compiled.finditer(text))
        if len(matches) >= occurrence:
            return matches[occurrence - 1]
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for layout log {pattern!r}; log: {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    parser.add_argument("--wine", action="store_true")
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name an executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-01-layout-"))
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        environment["WINEDEBUG"] = "-all"
        command = ["wine", str(binary)] if args.wine else [str(binary)]
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            window = x11.find_window(args.timeout)
            x11.lib.XMapRaised(x11.display, window)
            x11.lib.XSetInputFocus(x11.display, window, 1, 0)
            x11.lib.XSync(x11.display, 0)
            time.sleep(0.3)
            # Sample from x=2 so the active window's caret (drawn at the body's
            # left edge, x=2) is captured. The buffer is empty, so moving the
            # active window changes only the caret position; the default region
            # (x>=10) missed it and made this check a false "no change".
            initial_pixels = x11.pixels(window, 2, 220, 66, 130)

            x11.drag(window, (5, 50), (600, 100))
            wait_for_layout_line(log_path, r"layout: window 1 column 2 index 0 weight 1\.0000", args.timeout)
            time.sleep(0.2)
            if x11.pixels(window, 2, 220, 66, 130) == initial_pixels:
                raise HarnessFailure("moving the active window did not change rendered pixels")
            print("PASS: primary drag moves a window to another column")

            x11.drag(window, (403, 50), (403, 100))
            first_resize = wait_for_layout_line(
                log_path,
                r"layout: window 1 column 2 index 0 weight (1\.[0-9]*[1-9][0-9]*)",
                args.timeout,
            )
            if float(first_resize.group(1)) <= 1.0:
                raise HarnessFailure("in-place drag did not grow the first window against its successor")
            print("PASS: in-place drag resizes the first window against its successor")

            x11.drag(window, (403, 50), (403, 25))
            resize = wait_for_layout_line(
                log_path,
                r"layout: window 1 column 2 index 0 weight (0\.[0-9]+|1\.[0-9]+)",
                args.timeout,
                occurrence=3,
            )
            if float(resize.group(1)) >= float(first_resize.group(1)):
                raise HarnessFailure("vertical pair drag did not shrink the dragged upper window")
            print("PASS: vertical drag resizes the adjacent window pair")

            x11.drag(window, (403, 50), (600, 590))
            wait_for_layout_line(log_path, r"layout: window 1 column 2 index 1 weight ([0-9.]+)", args.timeout)
            print("PASS: vertical drag reorders windows within a column")

            x11.drag(window, (403, 25), (10, 25))
            crossing_resize = wait_for_layout_line(
                log_path,
                r"layout: column 2 index 1 weight ([0-9.]+)",
                args.timeout,
            )
            crossing_weight = float(crossing_resize.group(1))
            if crossing_weight <= 1.0:
                raise HarnessFailure("crossing a column boundary did not grow the dragged right column")
            print("PASS: crossing a column boundary resizes without reordering")

            x11.drag(window, (85, 25), (135, 25))
            column_resize = wait_for_layout_line(
                log_path,
                r"layout: column 2 index 1 weight (1\.[0-6][0-9]*)",
                args.timeout,
            )
            if float(column_resize.group(1)) >= crossing_weight:
                raise HarnessFailure("horizontal pair drag did not shrink the dragged right column")
            print("PASS: horizontal drag resizes the adjacent column pair")

            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            succeeded = True
            return 0
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)
        if x11 is not None:
            x11.close()
        if succeeded:
            print(f"layout X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
