#!/usr/bin/env python3
"""Real X11 soft-wrap and truncate/horizontal-scroll checks for M07.09."""

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


LONG_TEXT = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ目标0123456789"


def wait_for_log(log_path: Path, needle: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if needle in log_path.read_text(encoding="utf-8", errors="replace"):
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r}; log: {log_path}")


def ink(x11: X11, window: int, y_start: int, y_end: int) -> int:
    image = x11.image(window)
    try:
        count = 0
        for y in range(y_start, y_end):
            for x in range(45, 390):
                if x11.lib.XGetPixel(image, x, y) & 0xFFFFFF != 0x161616:
                    count += 1
        return count
    finally:
        x11.lib.XDestroyImage(image)


def click(x11: X11, window: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(1, True)
    x11.button(1, False)


def save(x11: X11) -> None:
    x11.key(0xFFE3, True)
    x11.tap(ord("s"))
    x11.key(0xFFE3, False)


def start(binary: Path, source: Path, sandbox: Path, log_path: Path, dpi_scales: str = "") -> tuple[subprocess.Popen[bytes], X11, int]:
    environment = os.environ.copy()
    environment["HAMMER_LOG"] = ""
    environment["XDG_STATE_HOME"] = str(sandbox / "state")
    if dpi_scales:
        environment["HAMMER_TEST_DPI_SCALES"] = dpi_scales
    log = log_path.open("wb")
    try:
        process = subprocess.Popen(
            [str(binary), str(source)],
            cwd=sandbox,
            stdin=subprocess.DEVNULL,
            stdout=log,
            stderr=subprocess.STDOUT,
            env=environment,
        )
    except BaseException:
        log.close()
        raise
    x11 = X11()
    window = x11.find_window(20.0)
    x11.lib.XMapRaised(x11.display, window)
    x11.lib.XSetInputFocus(x11.display, window, 1, 0)
    x11.lib.XSync(x11.display, 0)
    time.sleep(0.3)
    log.close()
    return process, x11, window


def stop(process: subprocess.Popen[bytes], x11: X11) -> None:
    if process.poll() is None:
        process.terminate()
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=2)
    x11.close()


def run_soft(binary: Path, sandbox: Path) -> None:
    source = sandbox / "soft.txt"
    source.write_text(f"{LONG_TEXT}\nnext\n", encoding="utf-8")
    log_path = sandbox / "soft.log"
    process, x11, window = start(binary, source, sandbox, log_path)
    try:
        wait_for_log(log_path, "wrap=Soft", 20.0)
        row_inks = [ink(x11, window, 66, 86), ink(x11, window, 88, 109), ink(x11, window, 111, 133)]
        if not all(value > 20 for value in row_inks):
            raise HarnessFailure(f"soft wrap did not render two long-line rows plus next: {row_inks}")
        print(f"PASS: soft mode renders the long line and next line on three visual rows: {row_inks}")

        initial = x11.pixels(window, 2, 390, 66, 140)
        x11.move(window, 60, 76)
        x11.button(6, True)
        x11.button(6, False)
        wait_for_log(log_path, "view: horizontal scroll window=1 offset=0.00", 20.0)
        time.sleep(0.2)
        if x11.pixels(window, 2, 390, 66, 140) != initial:
            raise HarnessFailure("horizontal input changed a soft-wrapped view")
        print("PASS: horizontal input leaves soft-wrapped content at offset zero")

        click(x11, window, 46, 100)
        x11.tap(ord(";"))
        save(x11)
        wait_for_log(log_path, f"file: saved {source}", 20.0)
        data = source.read_bytes()
        insertion = data.index(b";")
        if not 20 <= insertion < len(LONG_TEXT.encode()):
            raise HarnessFailure(f"second-row hit inserted at {insertion}, outside the wrapped middle")
        if not data.endswith(b"\nnext\n"):
            raise HarnessFailure("wrapped-row editing damaged the following logical line")
        print(f"PASS: clicking the second visual row inserts at wrapped source byte {insertion}")
        x11.tap(0xFF1B)
        wait_for_exit(process, 20.0, log_path)
    finally:
        stop(process, x11)


def run_truncate(binary: Path, sandbox: Path) -> None:
    source = sandbox / "truncate.txt"
    source.write_text(f"{LONG_TEXT}\nnext\n", encoding="utf-8")
    log_path = sandbox / "truncate.log"
    process, x11, window = start(binary, source, sandbox, log_path)
    try:
        wait_for_log(log_path, "wrap=Truncate", 20.0)
        row_inks = [ink(x11, window, 66, 86), ink(x11, window, 88, 109), ink(x11, window, 111, 133)]
        if row_inks[0] <= 20 or row_inks[1] <= 20 or row_inks[2] > 20:
            raise HarnessFailure(f"truncate mode produced unexpected row ink: {row_inks}")
        print(f"PASS: truncate mode keeps one row per logical line: {row_inks}")

        initial = x11.pixels(window, 2, 390, 66, 110)
        x11.move(window, 60, 76)
        x11.button(6, True)
        x11.button(6, False)
        wait_for_log(log_path, "view: horizontal scroll window=1 offset=64.00", 20.0)
        x11.move(window, 61, 76)
        time.sleep(1.0)
        if x11.pixels(window, 2, 390, 66, 110) == initial:
            raise HarnessFailure("horizontal scrolling did not change the truncated rendering")
        print("PASS: right-horizontal input scrolls the truncated view")

        x11.button(7, True)
        x11.button(7, False)
        wait_for_log(log_path, "view: horizontal scroll window=1 offset=0.00", 20.0)
        time.sleep(0.2)
        if x11.pixels(window, 2, 390, 66, 110) != initial:
            raise HarnessFailure("left-horizontal input did not restore offset zero")
        print("PASS: left-horizontal input clamps and restores the initial viewport")

        x11.button(6, True)
        x11.button(6, False)
        wait_for_log(log_path, "view: horizontal scroll window=1 offset=64.00", 20.0)
        click(x11, window, 46, 76)
        x11.tap(ord(";"))
        save(x11)
        wait_for_log(log_path, f"file: saved {source}", 20.0)
        data = source.read_bytes()
        insertion = data.index(b";")
        if not 3 <= insertion <= 15:
            raise HarnessFailure(f"scrolled hit inserted at {insertion}, expected a horizontally displaced source position")
        print(f"PASS: horizontal hit-testing inserts at scrolled source byte {insertion}")
        x11.tap(0xFF1B)
        wait_for_exit(process, 20.0, log_path)
    finally:
        stop(process, x11)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--soft", required=True, type=Path)
    parser.add_argument("--truncate", required=True, type=Path)
    args = parser.parse_args()
    soft = args.soft.resolve()
    truncate = args.truncate.resolve()
    if not soft.is_file() or not truncate.is_file():
        parser.error("--soft and --truncate must name executables")
    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-09-wrap-"))
    run_soft(soft, sandbox)
    run_truncate(truncate, sandbox)
    print(f"Wrap/scroll X11 smoke passed; sandbox: {sandbox}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
