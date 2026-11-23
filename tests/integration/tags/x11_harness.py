#!/usr/bin/env python3
"""Real X11 editable-tag and generated-command smoke test for M07.03."""

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
from x11_harness import HarnessFailure, X11, open_untitled, wait_for_exit  # noqa: E402


def wait_for_log(log_path: Path, needle: str, timeout: float) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if needle in log_path.read_text(encoding="utf-8", errors="replace"):
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r}; log: {log_path}")


def type_tag_text(x11: X11, text: str) -> None:
    """Types text with Shift for uppercase letters (tags are case-sensitive)."""
    for character in text:
        if character.isupper():
            x11.key(0xFFE1, True)
            x11.tap(ord(character.lower()))
            x11.key(0xFFE1, False)
        else:
            x11.tap(ord(character))


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-03-tags-"))
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

            body_initial = x11.pixels(window, 2, 390, 66, 320)
            window_tag_initial = x11.pixels(window, 22, 390, 46, 66)
            x11.move(window, 180, 52)
            x11.button(1, True)
            x11.button(1, False)
            time.sleep(0.2)
            body_inactive = x11.pixels(window, 2, 390, 66, 320)
            x11.tap(ord("X"))
            time.sleep(0.3)
            if x11.pixels(window, 22, 390, 46, 66) == window_tag_initial:
                raise HarnessFailure("typing in the window tag did not change its text")
            if x11.pixels(window, 2, 390, 66, 320) != body_inactive:
                raise HarnessFailure("typing in the window tag changed the body")
            print("PASS: window tag accepts text without editing the body")

            x11.move(window, 46, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("A"))
            wait_for_log(log_path, 'tag: window 3 generated "New Del Put | "', args.timeout)
            if x11.pixels(window, 2, 390, 66, 320) == body_initial:
                raise HarnessFailure("body typing did not change the body")
            print("PASS: dirty body state generates Put in the window tag")

            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, 'tag: window 3 generated "New Del | "', args.timeout)
            if x11.pixels(window, 2, 390, 66, 320) != body_initial:
                raise HarnessFailure("body undo did not restore the body")
            print("PASS: clean body state removes generated Put without undoing the tag")

            x11.move(window, 46, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("a"))
            x11.tap(0xFF0D)
            x11.tap(ord("b"))
            x11.key(0xFFE3, True)
            x11.tap(ord("a"))
            x11.tap(ord("c"))
            x11.key(0xFFE3, False)
            time.sleep(0.2)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            x11.move(window, 180, 52)
            x11.button(1, True)
            x11.button(1, False)
            time.sleep(0.2)
            single_line_tag = x11.pixels(window, 22, 390, 46, 66)
            x11.key(0xFFE3, True)
            x11.tap(ord("v"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "tag: newline input is not allowed", args.timeout)
            time.sleep(0.2)
            if x11.pixels(window, 22, 390, 46, 66) != single_line_tag:
                raise HarnessFailure("pasting CR/LF changed a single-line tag")
            if x11.pixels(window, 2, 390, 66, 320) != body_inactive:
                raise HarnessFailure("rejected tag paste changed the body")
            print("PASS: tag paste rejects CR/LF without modifying tag or body text")

            x11.tap(0xFF0D)
            x11.tap(0xFF8D)
            time.sleep(0.3)
            if x11.pixels(window, 22, 390, 46, 66) != single_line_tag:
                raise HarnessFailure("Enter or keypad Enter inserted a newline into a tag")
            print("PASS: Enter and keypad Enter are rejected in a single-line tag")

            column_initial = x11.pixels(window, 22, 390, 22, 42)
            x11.move(window, 180, 30)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("C"))
            time.sleep(0.3)
            if x11.pixels(window, 22, 390, 22, 42) == column_initial:
                raise HarnessFailure("typing in the column tag did not change its text")
            print("PASS: column tag has independent editable text")

            global_initial = x11.pixels(window, 2, 790, 2, 22)
            x11.move(window, 100, 10)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("G"))
            time.sleep(0.3)
            if x11.pixels(window, 2, 790, 2, 22) == global_initial:
                raise HarnessFailure("typing in the global tag did not change its text")
            if x11.pixels(window, 2, 390, 66, 320) != body_inactive:
                raise HarnessFailure("tag editing changed the clean body")
            print("PASS: global tag has independent editable text")

            # The global tag strip is the full tag height (20 logical px,
            # y in [2, 22)). A regression inset its height by 2*pad, which
            # clipped the bottom of the tag text at y=18. Verify the strip
            # still paints tag background at its bottom edge (away from text).
            image = x11.image(window)
            strip_bottom = x11.lib.XGetPixel(image, 300, 21) & 0xFFFFFF
            x11.lib.XDestroyImage(image)
            if strip_bottom != 0x262626:
                raise HarnessFailure(
                    f"global tag strip is clipped: bottom pixel #{strip_bottom:06x}, expected tag background 262626"
                )
            print("PASS: global tag strip is full height (text not clipped)")

            x11.quit()
            wait_for_exit(process, args.timeout, log_path)
            process = None

            # M09.detour-1: the generated-commands region of a window tag is
            # immutable against typing; the leftmost filepath is editable and
            # Get reads it.
            detour_a = sandbox / "a.txt"
            detour_b = sandbox / "b.txt"
            detour_a.write_bytes(b"A\n")
            detour_b.write_bytes(b"B\n")
            detour_log = sandbox / "detour-hammer.log"
            with detour_log.open("wb") as log:
                process = subprocess.Popen(
                    [str(binary), "a.txt"],
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

                # The window tag is "a.txt Del | ". Typing inside the generated
                # commands region is blocked.
                x11.move(window, 90, 52)
                x11.button(1, True)
                x11.button(1, False)
                x11.tap(ord("X"))
                wait_for_log(detour_log, "tag: generated commands are immutable", args.timeout)
                print("PASS: generated-commands region is immutable against typing")

                # Backspace and Tab are also rejected inside the commands
                # region: neither may delete nor insert into the immutable text.
                tag_pixels = x11.pixels(window, 22, 390, 46, 66)
                x11.tap(0xFF08)  # Backspace
                time.sleep(0.2)
                if x11.pixels(window, 22, 390, 46, 66) != tag_pixels:
                    raise HarnessFailure("backspace edited the generated-commands region")
                x11.tap(0xFF09)  # Tab
                time.sleep(0.2)
                if x11.pixels(window, 22, 390, 46, 66) != tag_pixels:
                    raise HarnessFailure("tab edited the generated-commands region")
                print("PASS: backspace and tab are rejected in the generated-commands region")

                # Select the filepath "a.txt" and type "b.txt", then Get.
                x11.move(window, 22, 52)
                x11.button(1, True)
                x11.button(1, False)
                x11.key(0xFFE1, True)
                for _ in range(5):
                    x11.tap(0xFF53)  # Right arrow
                x11.key(0xFFE1, False)
                type_tag_text(x11, "b.txt")
                x11.move(window, 180, 52)
                x11.button(1, True)
                x11.button(1, False)
                type_tag_text(x11, "Get")
                x11.key(0xFFE1, True)
                for _ in range(3):
                    x11.tap(0xFF51)  # Left arrow
                x11.key(0xFFE1, False)
                x11.move(window, 180, 52)
                x11.button(2, True)
                x11.button(2, False)
                wait_for_log(detour_log, "file: reloaded", args.timeout)
                if "b.txt" not in detour_log.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("Get did not reload the edited filepath")
                print("PASS: Get reloads the file named in the edited filepath")

                # The cross-file reload leaves the buffer dirty (existing
                # Get <path> behavior), so terminate directly rather than
                # expecting a clean Ctrl+Q.
                process.terminate()
                process.wait(timeout=2)
                process = None

            # A file window's editable filepath may name a directory. Get must
            # replace the file with that directory's listing instead of sending
            # the path through the regular-file loader.
            listing = sandbox / "listing"
            listing.mkdir()
            (listing / "inside.txt").write_bytes(b"inside\n")
            directory_log = sandbox / "directory-hammer.log"
            with directory_log.open("wb") as log:
                process = subprocess.Popen(
                    [str(binary), "a.txt"],
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

                x11.move(window, 22, 52)
                x11.button(1, True)
                x11.button(1, False)
                x11.key(0xFFE1, True)
                for _ in range(5):
                    x11.tap(0xFF53)
                x11.key(0xFFE1, False)
                type_tag_text(x11, "listing")
                x11.move(window, 180, 52)
                x11.button(1, True)
                x11.button(1, False)
                type_tag_text(x11, "Get")
                x11.key(0xFFE1, True)
                for _ in range(3):
                    x11.tap(0xFF51)
                x11.key(0xFFE1, False)
                x11.move(window, 180, 52)
                x11.button(2, True)
                x11.button(2, False)
                wait_for_log(directory_log, f"directory: reloaded {listing}", args.timeout)
                wait_for_log(
                    directory_log,
                    f'tag: window 1 generated "{listing}/ Del Get | "',
                    args.timeout,
                )
                if "is not a regular file" in directory_log.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("Get sent a directory through the regular-file loader")
                print("PASS: Get loads a directory named in a file window's tag")

                process.terminate()
                process.wait(timeout=2)
                process = None

            # M09.detour-1 (blank buffer): an untitled buffer has no real
            # filepath, so its whole tag is editable — including the generated
            # commands region.
            blank_log = sandbox / "blank-hammer.log"
            with blank_log.open("wb") as log:
                process = subprocess.Popen(
                    [str(binary)],
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
                open_untitled(x11, window, blank_log, args.timeout)

                # The blank tag is "New Del | ". Typing inside the generated
                # commands region is allowed.
                x11.move(window, 66, 52)
                x11.button(1, True)
                x11.button(1, False)
                tag_pixels = x11.pixels(window, 22, 390, 46, 66)
                x11.tap(ord("X"))
                time.sleep(0.3)
                if x11.pixels(window, 22, 390, 46, 66) == tag_pixels:
                    raise HarnessFailure("typing in a blank buffer's commands region was blocked")
                if "tag: generated commands are immutable" in blank_log.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("blank buffer tag was treated as immutable")
                print("PASS: blank buffer's whole tag is editable")

                process.terminate()
                process.wait(timeout=2)
                process = None

            # M09.detour-1 (save new file): typing a path into an untitled
            # buffer's tag offers Put, and middle-clicking Put writes the file.
            save_log = sandbox / "save-hammer.log"
            with save_log.open("wb") as log:
                process = subprocess.Popen(
                    [str(binary)],
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
                open_untitled(x11, window, save_log, args.timeout)

                # Replace the placeholder name "New" with a real path.
                x11.move(window, 22, 52)
                x11.button(1, True)
                x11.button(1, False)
                x11.key(0xFFE1, True)
                for _ in range(3):
                    x11.tap(0xFF53)  # Right arrow selects "New"
                x11.key(0xFFE1, False)
                type_tag_text(x11, "f.txt")

                # The tag is now "f.txt Del Put | "; middle-click Put.
                x11.move(window, 114, 52)
                x11.button(2, True)
                x11.button(2, False)
                wait_for_log(save_log, "file: saved", args.timeout)
                saved = sandbox / "f.txt"
                if not saved.is_file():
                    raise HarnessFailure("Put did not create the file at the typed path")
                print("PASS: Put saves an untitled buffer to the typed path")

                process.terminate()
                process.wait(timeout=2)
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
            print(f"tag X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
