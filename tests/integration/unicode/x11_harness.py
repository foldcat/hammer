#!/usr/bin/env python3
"""Real X11 Unicode shaping, fallback, rendering, and clipboard smoke test."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parent.parent / "typing"))
from x11_harness import ClipboardOwner, HarnessFailure, X11, read_external_clipboard, wait_for_exit

LINES = [
    "A̋e̋i̋őű n͍ s͍ t͍ p̾ b̾ d̾ t̾ g̾ k̾ c̾ m̃ ñ l̃ r̃",
    "Zͣaͣlͣgͣoͣ Tͣeͣsͣtͣ: Hͥeͣ cͦoͦmͦeͦsͣ",
    "Vowel stacking: ȁ ȅ ȉ ȍ ȕ y̏ ä̈ ë̈ ï̈ ö̈ ü̈",
    "Devanagari: नमस्ते कि ख क्षि ज्ञ",
    "Tamil: வணக்கம் தமிழ்",
    "Thai: สวัสดี ที่ ไหม",
    "Khmer: សួស្តី ខ្ញុំ",
    "Bidi: start אבג 123 مرحبا end",
    "Box: ┌─┬─┐ │ │ ├─┼─┤ └─┴─┘",
    "Blocks: ▀▁▂▃▄▅▆▇█",
    "Braille: ⠀⠁⠃⠇⡿⣿",
    "Math: ∀∑∫√∞≠≤≥  Currency: €£¥₹₿  Technical: ⌘⌥⇧⌫⏎",
]
FULL_TEXT = "\n".join(LINES)


def chord(x11: X11, modifier: int, keysym: int) -> None:
    x11.key(modifier, True)
    x11.tap(keysym)
    x11.key(modifier, False)
    time.sleep(0.2)


def line_ink(x11: X11, window: int, line: int) -> int:
    image = x11.image(window)
    count = 0
    try:
        top = 24 + round(line * 22.4)
        for y in range(top, min(top + 19, 600)):
            for x in range(4, 790):
                pixel = x11.lib.XGetPixel(image, x, y)
                r = (pixel >> 16) & 0xFF
                g = (pixel >> 8) & 0xFF
                b = pixel & 0xFF
                if max(r, g, b) > 80:
                    count += 1
        return count
    finally:
        x11.lib.XDestroyImage(image)


def write_png(path: Path, x11: X11, window: int) -> None:
    image = x11.image(window)
    try:
        rows = bytearray()
        for y in range(600):
            rows.append(0)
            for x in range(800):
                pixel = x11.lib.XGetPixel(image, x, y)
                rows.extend(((pixel >> 16) & 0xFF, (pixel >> 8) & 0xFF, pixel & 0xFF))
    finally:
        x11.lib.XDestroyImage(image)

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", 800, 600, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--clipboard-peer", required=True, type=Path)
    parser.add_argument("--screenshot", type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    clipboard_peer = args.clipboard_peer.resolve()
    if not binary.is_file() or not clipboard_peer.is_file():
        parser.error("--binary and --clipboard-peer must name executables")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m06-unicode-"))
    process: subprocess.Popen[bytes] | None = None
    clipboard_owner: ClipboardOwner | None = None
    x11: X11 | None = None
    succeeded = False
    log_path = sandbox / "hammer.log"
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        payload_path = sandbox / "unicode.txt"
        payload_path.write_bytes(FULL_TEXT.encode("utf-8"))
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=environment,
            )
            window = x11.find_window(args.timeout)
            x11.lib.XMapRaised(x11.display, window)
            x11.lib.XSetInputFocus(x11.display, window, 1, 0)
            x11.lib.XSync(x11.display, 0)
            time.sleep(0.3)

            clipboard_owner = ClipboardOwner(clipboard_peer, payload_path, sandbox, args.timeout)
            chord(x11, 0xFFE3, ord("v"))
            time.sleep(1.0)
            ink = [line_ink(x11, window, index) for index in range(len(LINES))]
            for index, count in enumerate(ink):
                if count < 20:
                    raise HarnessFailure(f"line {index + 1} has only {count} visible text pixels; log: {log_path}")
            print(f"PASS: all {len(LINES)} Unicode lines rendered; per-line ink samples: {ink}")
            if args.screenshot is not None:
                write_png(args.screenshot, x11, window)

            chord(x11, 0xFFE3, ord("a"))
            chord(x11, 0xFFE3, ord("c"))
            output_path = sandbox / "roundtrip.txt"
            read_external_clipboard(clipboard_peer, output_path, args.timeout)
            actual = output_path.read_bytes()
            if actual != FULL_TEXT.encode("utf-8"):
                raise HarnessFailure(f"clipboard payload mismatch: got {actual!r}")
            clipboard_owner.stop()
            clipboard_owner = None
            print("PASS: combining, complex-script, bidi, and symbol text round-trips byte-exactly")

            chord(x11, 0xFFE3, ord("z"))
            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None

        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        if "render-text:" in log_text:
            raise HarnessFailure(f"product reported a shaping/rendering error; log: {log_path}")
        for codepoint in ("U+0928", "U+0BB5", "U+0E2A", "U+179F", "U+2581", "U+2800"):
            if f"codepoint={codepoint}" not in log_text:
                raise HarnessFailure(f"no cached font fallback was loaded for {codepoint}; log: {log_path}")
        succeeded = True
        print("PASS: complex scripts and missing symbols loaded real fallback faces without render errors")
        return 0
    except (HarnessFailure, OSError) as error:
        print(f"FAIL: {error}; preserved sandbox: {sandbox}", file=sys.stderr)
        return 1
    finally:
        if clipboard_owner is not None:
            clipboard_owner.stop()
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
            shutil.rmtree(sandbox)


if __name__ == "__main__":
    raise SystemExit(main())
