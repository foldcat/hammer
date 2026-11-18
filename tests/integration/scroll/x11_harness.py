#!/usr/bin/env python3
"""Real X11 vertical viewport and scrollbar checks for M07.10."""

from __future__ import annotations

import argparse
import ctypes
import importlib.util
import re
import sys
import tempfile
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402

wrap_path = Path(__file__).resolve().parents[1] / "wrap" / "x11_harness.py"
wrap_spec = importlib.util.spec_from_file_location("wrap_x11_harness", wrap_path)
assert wrap_spec is not None and wrap_spec.loader is not None
wrap_harness = importlib.util.module_from_spec(wrap_spec)
wrap_spec.loader.exec_module(wrap_harness)
LONG_TEXT = wrap_harness.LONG_TEXT
save = wrap_harness.save
start = wrap_harness.start
stop = wrap_harness.stop
wait_for_log = wrap_harness.wait_for_log


def click_button(x11: X11, window: int, button: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(button, True)
    x11.button(button, False)


def track_colors(x11: X11, window: int) -> set[int]:
    image = x11.image(window)
    try:
        return {
            int(x11.lib.XGetPixel(image, x, y)) & 0xFFFFFF
            for y in range(66, 590)
            for x in range(2, 14)
        }
    finally:
        x11.lib.XDestroyImage(image)


def wait_for_count(log_path: Path, needle: str, count: int, timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.read_text(encoding="utf-8", errors="replace").count(needle) >= count:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r} occurrence {count}; log: {log_path}")


def last_origin(log_path: Path) -> tuple[int, int]:
    matches = re.findall(r"view: (?:vertical scroll|scrollbar (?:relative|absolute)) window=1 line=(\d+) row=(\d+)", log_path.read_text())
    if not matches:
        raise HarnessFailure(f"no viewport origin logged; log: {log_path}")
    line, row = matches[-1]
    return int(line), int(row)


def wait_for_origin(log_path: Path, expected: tuple[int, int], timeout: float = 20.0) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        try:
            if last_origin(log_path) == expected:
                return
        except HarnessFailure:
            pass
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for origin {expected}; last origin: {last_origin(log_path)}; log: {log_path}")


def run_mode(binary: Path, sandbox: Path, mode: str) -> None:
    source = sandbox / f"scroll-{mode}.txt"
    source.write_text(LONG_TEXT + "\n" + "".join(f"line{index:02d}\n" for index in range(60)), encoding="utf-8")
    log_path = sandbox / f"scroll-{mode}.log"
    process, x11, window = start(binary, source, sandbox, log_path)
    try:
        wait_for_log(log_path, f"wrap={mode.capitalize()}", 20.0)
        time.sleep(0.2)
        initial = x11.pixels(window, 2, 390, 66, 180)
        initial_track = x11.pixels(window, 2, 14, 66, 590)
        colors = track_colors(x11, window)
        if len(colors) < 2:
            raise HarnessFailure("long-document scrollbar did not paint distinct track and thumb colors")
        if any((color >> 16) & 0xFF != (color >> 8) & 0xFF or (color >> 8) & 0xFF != color & 0xFF for color in colors):
            raise HarnessFailure(f"scrollbar contains non-gray colors: {sorted(colors)}")
        if max(colors) > 0x808080:
            raise HarnessFailure(f"scrollbar thumb is too bright: {sorted(colors)}")
        print(f"PASS: {mode} scrollbar renders distinct dark-gray track and thumb colors")

        x11.move(window, 60, 100)
        x11.button(5, True)
        x11.button(5, False)
        wait_for_log(log_path, "view: vertical scroll window=1", 20.0)
        time.sleep(0.2)
        if last_origin(log_path) == (0, 0):
            raise HarnessFailure("vertical wheel input did not advance the origin")
        if x11.pixels(window, 2, 390, 66, 180) == initial:
            raise HarnessFailure("vertical wheel input did not change rendering")
        x11.button(4, True)
        x11.button(4, False)
        wait_for_log(log_path, "view: vertical scroll window=1 line=0 row=0", 20.0)
        time.sleep(0.2)
        if x11.pixels(window, 2, 390, 66, 180) != initial:
            raise HarnessFailure("reverse wheel input did not restore the initial viewport")
        print(f"PASS: {mode} wheel scrolling advances and restores the viewport")

        x11.move(window, 5, 70)
        x11.button(3, True)
        expected = (0, 1) if mode == "soft" else (1, 0)
        wait_for_log(log_path, f"view: scrollbar relative window=1 line={expected[0]} row={expected[1]}", 20.0)
        time.sleep(0.45)
        x11.button(3, False)
        if last_origin(log_path) == expected:
            raise HarnessFailure("held button 3 did not repeat scrolling")
        print(f"PASS: {mode} button 3 scrolls wrapped rows immediately and repeats while held")

        click_button(x11, window, 2, 5, 67)
        wait_for_count(log_path, "view: scrollbar absolute window=1 line=0 row=0", 1, 20.0)
        click_button(x11, window, 3, 5, 70)
        wait_for_count(log_path, f"view: scrollbar relative window=1 line={expected[0]} row={expected[1]}", 2, 20.0)
        click_button(x11, window, 1, 5, 70)
        wait_for_origin(log_path, (0, 0))
        click_button(x11, window, 3, 5, 400)
        wait_for_origin(log_path, (38, 0))
        click_button(x11, window, 2, 5, 67)
        wait_for_origin(log_path, (0, 0))
        x11.drag(window, (5, 70), (100, 650))
        wait_for_origin(log_path, (61, 0))
        time.sleep(0.2)
        if x11.pixels(window, 2, 14, 66, 590) == initial_track:
            raise HarnessFailure("scrollbar drag did not move the rendered thumb")
        click_button(x11, window, 2, 5, 67)
        wait_for_origin(log_path, (0, 0))
        print(f"PASS: {mode} non-thumb clicks jump and outside-track drags follow the pointer")

        x11.move(window, 5, 70)
        x11.button(3, True)
        x11.button(3, False)
        wait_for_count(log_path, f"view: scrollbar relative window=1 line={expected[0]} row={expected[1]}", 3, 20.0)
        click_button(x11, window, 1, 15, 76)
        x11.tap(ord(";"))
        save(x11)
        wait_for_log(log_path, f"file: saved {source}", 20.0)
        data = source.read_bytes()
        insertion = data.index(b";")
        if mode == "soft" and not 20 <= insertion < len(LONG_TEXT.encode()):
            raise HarnessFailure(f"wrapped-row click inserted at {insertion}, outside the second visual row")
        if mode == "truncate" and not data.startswith(LONG_TEXT.encode() + b"\n;line"):
            raise HarnessFailure(f"truncate scrolled-row click inserted at unexpected byte {insertion}")
        print(f"PASS: {mode} scrolled hit-testing inserts at source byte {insertion}")

        x11.lib.XResizeWindow.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_uint, ctypes.c_uint]
        x11.lib.XResizeWindow(x11.display, window, 900, 500)
        x11.lib.XSync(x11.display, 0)
        time.sleep(0.3)
        if process.poll() is not None:
            raise HarnessFailure("editor exited while resizing a scrolled view")
        x11.move(window, 60, 100)
        x11.button(5, True)
        x11.button(5, False)
        wait_for_count(log_path, "view: vertical scroll window=1", 3, 20.0)
        print(f"PASS: {mode} viewport remains scrollable after resize")

        save(x11)
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
    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-10-scroll-"))
    run_mode(soft, sandbox, "soft")
    run_mode(truncate, sandbox, "truncate")
    print(f"Viewport/scrollbar X11 smoke passed; sandbox: {sandbox}")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
