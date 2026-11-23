#!/usr/bin/env python3
"""Real X11 Look expansion and independent-file-opening smoke test for M07.06."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402


def caret_column(x11: X11, window: int) -> tuple[int, int]:
    image = x11.image(window)
    try:
        best_x, best_run = 0, 0
        for x in range(40, 180):
            run = 0
            for y in range(480, 530):
                if int(x11.lib.XGetPixel(image, x, y)) & 0xFFFFFF == 0xF2F4F8:
                    run += 1
                    if run > best_run:
                        best_x, best_run = x, run
                else:
                    run = 0
        return best_x, best_run
    finally:
        x11.lib.XDestroyImage(image)


def wait_for_log(log_path: Path, needle: str, timeout: float, occurrence: int = 1) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.read_text(encoding="utf-8", errors="replace").count(needle) >= occurrence:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r} occurrence {occurrence}; log: {log_path}")


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-06-look-"))
    target = sandbox / "target.txt"
    target.write_bytes(b"first\nsecond target\nthird\n")
    unicode_target = sandbox / "目标.txt"
    unicode_target.write_bytes(b"unicode\n")
    coltarget = sandbox / "sub" / "coltarget.txt"
    coltarget.parent.mkdir()
    coltarget.write_bytes(b"0123456789\n")
    source = sandbox / "source.txt"
    source.write_text(f"target.txt:2\n{unicode_target}\nmissing-token\ncoltarget.txt:1:5\n", encoding="utf-8")
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

            x11.move(window, 91, 76)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(log_path, f"look: opened {target} window=3 buffer=3 line=2", args.timeout)
            x11.tap(ord("x"))
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, f"file: saved {target}", args.timeout)
            if target.read_bytes() != b"first\nx\nthird\n":
                raise HarnessFailure(f"file:line opened or saved the wrong buffer: {target.read_bytes()!r}")
            if source.read_bytes() != f"target.txt:2\n{unicode_target}\nmissing-token\ncoltarget.txt:1:5\n".encode():
                raise HarnessFailure("opening a file changed the source document")
            print("PASS: relative file:line Look opens the target at its line and saves only that buffer")

            x11.move(window, 46, 96)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(log_path, f"look: opened {unicode_target} window=4 buffer=4 line=0", args.timeout)
            x11.tap(ord("u"))
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, f"file: saved {unicode_target}", args.timeout)
            if unicode_target.read_bytes() != b"uunicode\n":
                raise HarnessFailure(f"Unicode path saved unexpected bytes: {unicode_target.read_bytes()!r}")
            print("PASS: absolute Unicode paths open as independent editable files")

            x11.move(window, 91, 76)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(log_path, f"look: activated {target} window=3 buffer=3 line=2", args.timeout)
            if log_path.read_text(encoding="utf-8", errors="replace").count("look: opened ") != 2:
                raise HarnessFailure("reopening a path created a duplicate buffer or window")
            print("PASS: reopening a normalized path activates its existing buffer and view")

            x11.move(window, 46, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(0xFF50)
            x11.key(0xFFE3, False)
            x11.tap(ord("s"))
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, f"file: saved {source}", args.timeout)
            expected_source = f"starget.txt:2\n{unicode_target}\nmissing-token\ncoltarget.txt:1:5\n".encode()
            if source.read_bytes() != expected_source:
                raise HarnessFailure(f"source buffer saved unexpected bytes: {source.read_bytes()!r}")
            if target.read_bytes() != b"first\nx\nthird\n" or unicode_target.read_bytes() != b"uunicode\n":
                raise HarnessFailure("saving the source buffer modified a Look-opened file")
            print("PASS: source and Look-opened buffers edit and save independently")

            x11.move(window, 46, 170)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(log_path, f"look: opened {coltarget} window=5 buffer=5 line=1 col=5", args.timeout)
            time.sleep(0.2)
            caret_x, caret_run = caret_column(x11, window)
            if not 75 <= caret_x <= 95 or caret_run < 15:
                raise HarnessFailure(f"file:line:col caret rendered at x={caret_x} with run={caret_run}, want column 5")
            x11.tap(ord("x"))
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, f"file: saved {coltarget}", args.timeout)
            if coltarget.read_bytes() != b"x\n":
                raise HarnessFailure(f"file:line:col did not select the whole line: {coltarget.read_bytes()!r}")
            if source.read_bytes() != expected_source:
                raise HarnessFailure("opening a file:line:col reference changed the source document")
            print("PASS: file:line:col Look highlights the whole line and keeps the addressed caret")

            missing_start = len(f"starget.txt:2\n{unicode_target}\n".encode())
            missing_end = missing_start + len(b"missing-token")
            x11.move(window, 101, 140)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(
                log_path,
                f'mouse: look "missing-token" reverse=false match=[{missing_start},{missing_end})',
                args.timeout,
            )
            if log_path.read_text(encoding="utf-8", errors="replace").count("look: opened ") != 3:
                raise HarnessFailure("a missing filename created a buffer instead of using literal search")
            print("PASS: missing filenames fall back to wrapped literal search")

            x11.tap(ord("d"))
            x11.move(window, 46, 356)
            x11.button(1, True)
            x11.button(1, False)
            x11.quit()
            time.sleep(0.3)
            if process.poll() is not None:
                raise HarnessFailure("quit discarded a dirty buffer while another buffer was active")
            wait_for_log(log_path, "edit: unsaved text; close blocked", args.timeout)
            print("PASS: quitting checks dirty buffers even when another buffer is active")

            x11.move(window, 46, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            x11.quit()
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
            print(f"Look X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
