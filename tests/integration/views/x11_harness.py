#!/usr/bin/env python3
"""Real X11 independent-buffer/view smoke test for M07.02 and M07.06."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402


def wait_for_log(log_path: Path, needle: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if needle in log_path.read_text(encoding="utf-8", errors="replace"):
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r}; log: {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name an executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-02-views-"))
    source = sandbox / "source.txt"
    source.write_bytes(b"alpha\n")
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary), str(source)],
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

            x11.tap(ord("X"))
            x11.drag(window, (3, 76), (55, 76))
            time.sleep(0.2)
            if x11.selection_pixels(window, 60, 310) < 20:
                raise HarnessFailure("the first window did not own its initial selection")

            x11.move(window, 3, 356)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("Y"))
            x11.drag(window, (3, 356), (50, 356))
            time.sleep(0.2)
            if x11.selection_pixels(window, 60, 310) < 20:
                raise HarnessFailure("selecting in the second window cleared the first window's selection")
            if x11.selection_pixels(window, 345, 590) < 20:
                raise HarnessFailure("the second window did not render its own selection")
            print("PASS: independent buffers retain independent visible selections")

            x11.move(window, 3, 356)
            x11.button(1, True)
            x11.button(1, False)
            time.sleep(0.2)
            if x11.selection_pixels(window, 60, 310) < 20:
                raise HarnessFailure("collapsing the second view's selection changed the first view")
            if x11.selection_pixels(window, 345, 590) != 0:
                raise HarnessFailure("the second view's selection did not collapse")
            print("PASS: changing the active view preserves the inactive view's selection")

            x11.move(window, 3, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "file: saved ", args.timeout)
            if source.read_bytes() != b"xalpha\n":
                raise HarnessFailure(f"typing leaked between independent buffers: {source.read_bytes()!r}")
            print("PASS: typing in one window does not appear in another window's buffer")

            x11.move(window, 3, 356)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("w"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "view: closed window 2; 2 views remain", args.timeout)
            if process.poll() is not None:
                raise HarnessFailure("closing one of several views exited the editor")
            print("PASS: closing one view preserves the other independent buffers")

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
            print(f"view X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
