#!/usr/bin/env python3
"""Integrated Acme window-behavior compatibility scenario for M07.08."""

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


def wait_for_log(log_path: Path, needle: str, timeout: float, occurrence: int = 1) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.read_text(encoding="utf-8", errors="replace").count(needle) >= occurrence:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r} occurrence {occurrence}; log: {log_path}")


def click(x11: X11, window: int, button: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(button, True)
    x11.button(button, False)


def save(x11: X11) -> None:
    x11.key(0xFFE3, True)
    x11.tap(ord("s"))
    x11.key(0xFFE3, False)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name an executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-08-compatibility-"))
    source = sandbox / "source.txt"
    child = sandbox / "child.txt"
    source.write_bytes(b"alpha\nchild.txt\n")
    child.write_bytes(b"child\n")
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
                cwd=sandbox,
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
            wait_for_log(log_path, f"file: opened {source}", args.timeout)
            wait_for_log(log_path, f"directory: opened {sandbox}/ buffer=2", args.timeout)
            print("PASS: requested file and working-directory explorer coexist at startup")

            x11.drag(window, (3, 76), (55, 76))
            x11.tap(ord("x"))
            wait_for_log(log_path, 'tag: window 1 generated "source.txt Del Put | "', args.timeout)
            click(x11, window, 2, 175, 52)
            wait_for_log(log_path, f"file: saved {source}", args.timeout)
            if source.read_bytes() != b"x\nchild.txt\n":
                raise HarnessFailure(f"mouse selection or tag Put produced unexpected bytes: {source.read_bytes()!r}")
            print("PASS: primary selection, editing, dirty tag state, and button-2 Put compose")

            click(x11, window, 3, 420, 76)
            wait_for_log(log_path, f"look: opened {child} window=3 buffer=3 line=0", args.timeout)
            if source.read_bytes() != b"x\nchild.txt\n" or child.read_bytes() != b"child\n":
                raise HarnessFailure("opening from the explorer changed an existing file")
            print("PASS: button 3 opens an explorer entry as an independent file window")

            x11.drag(window, (403, 330), (10, 100))
            wait_for_log(log_path, "layout: window 3 column 1 index 0 weight 1.0000", args.timeout)
            print("PASS: the explorer-opened window drags into the source column")

            click(x11, window, 1, 500, 76)
            save(x11)
            wait_for_log(log_path, "errors: opened window=4 buffer=4", args.timeout)
            save(x11)
            wait_for_log(log_path, "errors: appended window=4 buffer=4", args.timeout)
            if log_path.read_text(encoding="utf-8", errors="replace").count("errors: opened ") != 1:
                raise HarnessFailure("repeated errors created duplicate windows")
            print("PASS: directory errors reuse +Errors without stealing the originating window")

            click(x11, window, 1, 60, 76)
            x11.tap(ord("q"))
            click(x11, window, 1, 60, 356)
            x11.tap(0xFF1B)
            time.sleep(0.3)
            if process.poll() is not None:
                raise HarnessFailure("quit discarded an inactive dirty Look-opened buffer")
            wait_for_log(log_path, "edit: unsaved text; close blocked", args.timeout)
            print("PASS: quit inspects inactive dirty windows after layout and error operations")

            click(x11, window, 1, 60, 76)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            click(x11, window, 2, 130, 330)
            wait_for_log(log_path, "view: closed window 1; 3 views remain", args.timeout)
            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None
            succeeded = True
            print("PASS: undo restores clean state and button-2 Del uses the safe close path")
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
            print(f"Window compatibility X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
