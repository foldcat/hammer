#!/usr/bin/env python3
"""Real X11 color-emoji sequence rendering and grapheme-deletion smoke test."""

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
from x11_harness import ClipboardOwner, HarnessFailure, X11, open_untitled, read_external_clipboard, wait_for_exit

FULL_TEXT = "A👩\u200d💻👍🏽👨\u200d👩\u200d👧\u200d👦❤️🇨🇦1️⃣B"


def colored_pixels(x11: X11, window: int) -> int:
    image = x11.image(window)
    count = 0
    try:
        for y in range(24, 90):
            for x in range(2, 300):
                pixel = x11.lib.XGetPixel(image, x, y)
                r = (pixel >> 16) & 0xFF
                g = (pixel >> 8) & 0xFF
                b = pixel & 0xFF
                if max(r, g, b) > 60 and max(r, g, b) - min(r, g, b) > 30:
                    count += 1
        return count
    finally:
        x11.lib.XDestroyImage(image)


def chord(x11: X11, modifier: int, keysym: int) -> None:
    x11.key(modifier, True)
    x11.tap(keysym)
    x11.key(modifier, False)
    time.sleep(0.25)


def expect_clipboard(peer: Path, x11: X11, window: int, output: Path, expected: str, timeout: float) -> None:
    time.sleep(0.3)
    chord(x11, 0xFFE3, ord("a"))
    chord(x11, 0xFFE3, ord("c"))
    read_external_clipboard(peer, output, timeout)
    actual = output.read_bytes()
    if actual != expected.encode("utf-8"):
        raise HarnessFailure(f"clipboard payload mismatch: got {actual!r}, want {expected.encode('utf-8')!r}")
    x11.tap(0xFF53)
    time.sleep(0.2)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--clipboard-peer", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    clipboard_peer = args.clipboard_peer.resolve()
    if not binary.is_file() or not clipboard_peer.is_file():
        parser.error("--binary and --clipboard-peer must name executables")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m05-10-emoji-"))
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
        payload_path = sandbox / "emoji.txt"
        payload_path.write_bytes(FULL_TEXT.encode("utf-8"))
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary)],
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
            open_untitled(x11, window, log_path, args.timeout)
            initial = x11.pixels(window)

            clipboard_owner = ClipboardOwner(clipboard_peer, payload_path, sandbox, args.timeout)
            time.sleep(0.2)
            chord(x11, 0xFFE3, ord("v"))
            time.sleep(0.8)
            colors = colored_pixels(x11, window)
            if colors < 20:
                raise HarnessFailure(f"only {colors} colored emoji pixels were rendered; log: {log_path}")
            print(f"PASS: product renders native color emoji pixels ({colors} colored samples)")

            expect_clipboard(clipboard_peer, x11, window, sandbox / "full.txt", FULL_TEXT, args.timeout)
            clipboard_owner.stop()
            clipboard_owner = None
            print("PASS: ZWJ, skin-tone, family, VS16, flag, and keycap sequences round-trip byte-exactly")

            for _ in range(2):
                x11.tap(0xFF08)
            expect_clipboard(
                clipboard_peer, x11, window, sandbox / "flag.txt",
                "A👩\u200d💻👍🏽👨\u200d👩\u200d👧\u200d👦❤️🇨🇦", args.timeout,
            )
            x11.tap(0xFF08)
            expect_clipboard(
                clipboard_peer, x11, window, sandbox / "heart.txt",
                "A👩\u200d💻👍🏽👨\u200d👩\u200d👧\u200d👦❤️", args.timeout,
            )
            x11.tap(0xFF08)
            expect_clipboard(
                clipboard_peer, x11, window, sandbox / "family.txt",
                "A👩\u200d💻👍🏽👨\u200d👩\u200d👧\u200d👦", args.timeout,
            )
            x11.tap(0xFF08)
            expect_clipboard(clipboard_peer, x11, window, sandbox / "thumb.txt", "A👩\u200d💻👍🏽", args.timeout)
            x11.tap(0xFF08)
            expect_clipboard(clipboard_peer, x11, window, sandbox / "woman.txt", "A👩\u200d💻", args.timeout)
            x11.tap(0xFF08)
            expect_clipboard(clipboard_peer, x11, window, sandbox / "ascii.txt", "A", args.timeout)
            x11.tap(0xFF08)
            time.sleep(0.3)
            if x11.pixels(window) != initial:
                raise HarnessFailure("eight Backspaces did not remove eight source graphemes")
            print("PASS: ordinary Backspace deletes each complete emoji sequence")

            for _ in range(9):
                chord(x11, 0xFFE3, ord("z"))
            if x11.pixels(window) != initial:
                raise HarnessFailure("undo after emoji edits did not restore the initial document")
            x11.quit()
            wait_for_exit(process, args.timeout, log_path)
            process = None

        log_text = log_path.read_text(encoding="utf-8", errors="replace")
        if "render-text:" in log_text or "fonts: role=emoji" not in log_text:
            raise HarnessFailure(f"emoji fallback or rendering failed; log: {log_path}")
        succeeded = True
        print("PASS: all X11 color-emoji product checks")
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
