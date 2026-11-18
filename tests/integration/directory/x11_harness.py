#!/usr/bin/env python3
"""Real X11 directory-window and +Errors smoke test for M07.07."""

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


def look(x11: X11, window: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(3, True)
    x11.button(3, False)


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-07-directory-"))
    root = sandbox / "root"
    sub = root / "sub"
    sub.mkdir(parents=True)
    alpha = root / "alpha.txt"
    alpha.write_bytes(b"alpha\n")
    (root / "zeta.txt").write_bytes(b"zeta\n")
    (root / "目标.txt").write_bytes(b"unicode\n")
    nested = sub / "nested.txt"
    nested.write_bytes(b"nested\n")
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
                [str(binary), str(root)],
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
            wait_for_log(log_path, f"directory: opened {root}/ buffer=1 bytes=", args.timeout)
            wait_for_log(log_path, f"directory: opened {Path.cwd().resolve()}/ buffer=2 bytes=", args.timeout)
            print("PASS: startup opens the requested directory and a working-directory explorer")

            look(x11, window, 60, 76)
            wait_for_log(log_path, f"look: opened {alpha} window=3 buffer=3 line=0", args.timeout)
            x11.tap(ord("x"))
            save(x11)
            wait_for_log(log_path, f"file: saved {alpha}", args.timeout)
            if alpha.read_bytes() != b"xalpha\n":
                raise HarnessFailure(f"directory-relative file saved unexpected bytes: {alpha.read_bytes()!r}")
            if nested.read_bytes() != b"nested\n":
                raise HarnessFailure("saving a directory entry modified another file")
            print("PASS: directory entry Look resolves relative to the listing and saves independently")

            look(x11, window, 46, 102)
            wait_for_log(log_path, f"look: opened {sub} window=4 buffer=4 line=0", args.timeout)
            wait_for_log(log_path, f"directory: opened {sub}/ buffer=4 bytes=", args.timeout)
            print("PASS: a slash-marked subdirectory opens another three-lane directory window")

            look(x11, window, 60, 450)
            wait_for_log(log_path, f"look: opened {nested} window=5 buffer=5 line=0", args.timeout)
            print("PASS: nested directory entries resolve against the immediate listing")

            message = "save: directory and error windows cannot be saved as files"
            error_bytes = len(message.encode()) + 1
            x11.move(window, 500, 76)
            x11.button(1, True)
            x11.button(1, False)
            save(x11)
            wait_for_log(log_path, f"errors: opened window=6 buffer=6 bytes={error_bytes}", args.timeout)
            x11.move(window, 500, 76)
            x11.button(1, True)
            x11.button(1, False)
            save(x11)
            wait_for_log(log_path, f"errors: appended window=6 buffer=6 bytes={2 * error_bytes}", args.timeout)
            text = log_path.read_text(encoding="utf-8", errors="replace")
            if text.count("errors: opened ") != 1:
                raise HarnessFailure("a second error created a duplicate +Errors window")
            print("PASS: errors accumulate through transactions in one reusable +Errors window")

            x11.move(window, 500, 360)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("e"))
            x11.move(window, 500, 76)
            x11.button(1, True)
            x11.button(1, False)
            save(x11)
            wait_for_log(log_path, f"errors: appended window=6 buffer=6 bytes={3 * error_bytes + 1}", args.timeout)
            x11.tap(0xFF1B)
            time.sleep(0.3)
            if process.poll() is not None:
                raise HarnessFailure("an automatic error append cleared user-dirty state and allowed lossy quit")
            wait_for_log(log_path, "edit: unsaved text; close blocked", args.timeout)
            print("PASS: automatic error output preserves user-dirty close protection")

            x11.move(window, 500, 360)
            x11.button(1, True)
            x11.button(1, False)
            for _ in range(2):
                x11.key(0xFFE3, True)
                x11.tap(ord("z"))
                x11.key(0xFFE3, False)
            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None
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
            print(f"Directory/error X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
