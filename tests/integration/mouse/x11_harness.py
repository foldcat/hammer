#!/usr/bin/env python3
"""Real X11 Acme mouse action and chord smoke test for M07.04."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import ClipboardOwner, HarnessFailure, X11, read_external_clipboard, wait_for_exit  # noqa: E402


def wait_for_log(log_path: Path, needle: str, timeout: float, occurrence: int = 1) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        text = log_path.read_text(encoding="utf-8", errors="replace")
        if text.count(needle) >= occurrence:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r} occurrence {occurrence}; log: {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--clipboard-peer", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    clipboard_peer = args.clipboard_peer.resolve()
    if not binary.is_file() or not clipboard_peer.is_file():
        parser.error("--binary and --clipboard-peer must name executables")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m07-04-mouse-"))
    source = sandbox / "a.txt"
    source.write_bytes(b"alpha beta alpha\nLook\nPut\n")
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    clipboard_owner: ClipboardOwner | None = None
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        payload = sandbox / "payload.txt"
        payload.write_bytes(b"Z")
        clipboard_owner = ClipboardOwner(clipboard_peer, payload, sandbox, args.timeout)
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

            clipboard_owner.stop()
            clipboard_owner = None
            x11.move(window, 3, 76)
            x11.button(1, True)
            for x in (12, 22, 32, 40):
                x11.move(window, x, 76)
                time.sleep(0.03)
            x11.button(3, True)
            x11.button(3, False)
            x11.button(1, False)
            wait_for_log(log_path, "clipboard: selection has no owner or refused UTF-8 conversion", args.timeout)
            if "mouse: chord Paste applied transaction=" in log_path.read_text(encoding="utf-8"):
                raise HarnessFailure("empty clipboard unexpectedly applied a paste transaction")
            clipboard_owner = ClipboardOwner(clipboard_peer, payload, sandbox, args.timeout)
            x11.move(window, 250, 130)
            x11.button(1, True)
            x11.button(1, False)
            print("PASS: empty clipboard warns without editing and later chords still work")

            x11.move(window, 15, 76)
            x11.button(3, True)
            x11.button(3, False)
            wait_for_log(log_path, 'mouse: look "alpha" reverse=false match=[11,16)', args.timeout)
            if x11.selection_pixels(window) < 20:
                raise HarnessFailure("button 3 did not render the next literal match as selected")
            print("PASS: button 3 expands a token and selects the next literal match")

            x11.move(window, 3, 76)
            x11.button(1, True)
            for x in (12, 22, 32, 40):
                x11.move(window, x, 76)
                time.sleep(0.03)
            x11.button(1, False)
            x11.move(window, 15, 96)
            x11.button(2, True)
            x11.button(1, True)
            x11.button(2, False)
            x11.button(1, False)
            wait_for_log(log_path, 'mouse: execute "Look" target=3001 argument_chord=true', args.timeout)
            wait_for_log(log_path, 'mouse: look "alpha" reverse=false match=[11,16)', args.timeout)
            print("PASS: 2-1 supplies the last primary selection as a distinct Look argument")

            x11.move(window, 15, 76)
            x11.button(1, True)
            x11.button(1, False)
            time.sleep(0.05)
            x11.button(1, True)
            x11.button(2, True)
            wait_for_log(log_path, "mouse: chord Cut applied transaction=", args.timeout)
            x11.button(3, True)
            wait_for_log(log_path, "mouse: reversed Cut chord restored the original text and selection", args.timeout)
            x11.button(3, False)
            x11.button(2, False)
            x11.button(1, False)
            copied = sandbox / "copied.txt"
            read_external_clipboard(clipboard_peer, copied, args.timeout)
            if copied.read_bytes() != b"alpha":
                raise HarnessFailure(f"1-2-3 snarf produced {copied.read_bytes()!r}, want b'alpha'")
            print("PASS: double-click expansion plus 1-2-3 snarfs a word and restores clean text")

            x11.move(window, 180, 76)
            x11.button(1, True)
            x11.button(3, True)
            x11.button(3, False)
            x11.button(1, False)
            wait_for_log(log_path, "mouse: chord Paste applied transaction=", args.timeout)
            if x11.selection_pixels(window) < 20:
                raise HarnessFailure("collapsed-caret chord paste did not highlight the inserted text")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: 1-3 inserts at a collapsed caret and highlights the pasted text")

            x11.move(window, 180, 76)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("v"))
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            if x11.selection_pixels(window) != 0:
                raise HarnessFailure("Ctrl+V incorrectly retained a mouse-chord-style selection")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: Ctrl+V inserts at the caret without selecting the pasted text")

            x11.move(window, 70, 76)
            x11.button(1, True)
            x11.button(1, False)
            time.sleep(0.05)
            x11.button(1, True)
            x11.button(3, True)
            x11.move(window, 72, 78)
            x11.button(3, False)
            x11.button(1, False)
            wait_for_log(log_path, "mouse: chord Paste applied transaction=", args.timeout, occurrence=2)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: quick 1-3 release pastes from Hammer's own clipboard after Snarf")

            clipboard_owner.stop()
            clipboard_owner = ClipboardOwner(clipboard_peer, payload, sandbox, args.timeout)
            x11.move(window, 3, 76)
            x11.button(1, True)
            for x in (12, 22, 32, 40):
                x11.move(window, x, 76)
                time.sleep(0.03)
            x11.button(3, True)
            wait_for_log(log_path, "mouse: chord Paste applied transaction=", args.timeout, occurrence=3)
            x11.button(2, True)
            wait_for_log(log_path, "mouse: reversed Paste chord restored the original text and selection", args.timeout)
            x11.button(2, False)
            x11.button(3, False)
            x11.button(1, False)
            print("PASS: 1-3-2 reverses only the chord paste")

            x11.move(window, 20, 150)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("X"))
            x11.move(window, 15, 116)
            x11.button(2, True)
            x11.button(2, False)
            wait_for_log(log_path, "file: saved ", args.timeout)
            if source.read_bytes() != b"alpha beta alpha\nLook\nPut\nx":
                raise HarnessFailure(f"button-2 Put wrote unexpected bytes: {source.read_bytes()!r}")
            print("PASS: button 2 expands and executes Put without a primary selection")

            marker = sandbox / "must-not-exist"
            x11.move(window, 100, 10)
            x11.button(1, True)
            x11.button(1, False)
            x11.key(0xFFE3, True)
            x11.tap(ord("a"))
            x11.key(0xFFE3, False)
            for keysym in f"touch {marker}".encode("ascii"):
                x11.tap(keysym)
            x11.key(0xFFE3, True)
            x11.tap(ord("a"))
            x11.key(0xFFE3, False)
            x11.move(window, 100, 10)
            x11.button(2, True)
            x11.button(2, False)
            wait_for_log(log_path, 'mouse: command "touch" was not executed', args.timeout)
            time.sleep(0.2)
            if marker.exists():
                raise HarnessFailure("unknown button-2 text unexpectedly executed a shell command")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: selected unknown text is reported but never falls through to a shell")

            x11.move(window, 80, 52)
            x11.button(1, True)
            x11.button(1, False)
            x11.tap(ord("x"))
            x11.key(0xFFE3, True)
            x11.tap(ord("a"))
            x11.tap(ord("c"))
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            tag_copy = sandbox / "tag-copy.txt"
            read_external_clipboard(clipboard_peer, tag_copy, args.timeout)
            if tag_copy.read_bytes() != b"a.txt xDel | ":
                raise HarnessFailure(f"tag caret landed at the wrong byte: {tag_copy.read_bytes()!r}")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: window-tag hit testing uses the rendered text origin")

            x11.move(window, 70, 76)
            x11.button(1, True)
            for x in (85, 105, 130, 155, 180):
                x11.move(window, x, 76)
                time.sleep(0.03)
            x11.button(2, True)
            x11.button(2, False)
            x11.button(1, False)
            wait_for_log(log_path, "mouse: chord Cut applied transaction=", args.timeout, occurrence=2)
            x11.key(0xFFE3, True)
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "file: saved ", args.timeout, occurrence=2)
            remaining = source.read_bytes()
            if not remaining.startswith(b"alpha b") or not remaining.endswith(b"\nLook\nPut\nx"):
                raise HarnessFailure(f"drag-to-end cut removed unintended text: {remaining!r}")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.tap(ord("s"))
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "file: saved ", args.timeout, occurrence=3)
            if source.read_bytes() != b"alpha beta alpha\nLook\nPut\nx":
                raise HarnessFailure("undo did not restore the exact drag-to-end source text")
            print("PASS: drag-to-end 1-2 removes only the selected suffix")

            x11.move(window, 85, 52)
            x11.button(2, True)
            x11.button(2, False)
            wait_for_log(log_path, 'mouse: execute "Del" target=2001 argument_chord=false', args.timeout)
            wait_for_log(log_path, "view: closed window 1; 2 views remain", args.timeout)
            print("PASS: button-2 Del in a window tag uses the safe per-view close path")

            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None

            single = sandbox / "single.txt"
            single.write_bytes(b"alpha beta alpha")
            cut_log = sandbox / "drag-end.log"
            clipboard_owner.stop()
            clipboard_owner = None
            with cut_log.open("wb") as log:
                process = subprocess.Popen(
                    [str(binary), str(single)],
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
                x11.move(window, 23, 80)
                x11.button(1, True)
                x11.move(window, 176, 89)
                x11.button(3, True)
                x11.button(3, False)
                x11.button(1, False)
                wait_for_log(cut_log, "clipboard: selection has no owner or refused UTF-8 conversion", args.timeout)
                x11.move(window, 121, 117)
                x11.button(1, True)
                x11.button(1, False)
                for iteration in range(1, 11):
                    x11.move(window, 70, 76)
                    x11.button(1, True)
                    for x in (85, 105, 130, 155, 180):
                        x11.move(window, x, 76)
                        time.sleep(0.03)
                    x11.button(2, True)
                    x11.button(2, False)
                    x11.button(1, False)
                    wait_for_log(cut_log, "mouse: chord Cut applied transaction=", args.timeout, occurrence=iteration)
                    x11.key(0xFFE3, True)
                    x11.tap(ord("s"))
                    x11.key(0xFFE3, False)
                    wait_for_log(cut_log, "file: saved ", args.timeout, occurrence=2 * iteration - 1)
                    if single.read_bytes() != b"alpha b":
                        raise HarnessFailure(
                            f"document-end cut {iteration} removed unintended bytes: {single.read_bytes()!r}"
                        )
                    x11.key(0xFFE3, True)
                    x11.tap(ord("z"))
                    x11.tap(ord("s"))
                    x11.key(0xFFE3, False)
                    wait_for_log(cut_log, "file: saved ", args.timeout, occurrence=2 * iteration)
                    if single.read_bytes() != b"alpha beta alpha":
                        raise HarnessFailure(f"cut/undo cycle {iteration} did not restore the source")
                if "render-text:" in cut_log.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure(f"cut left a stale selection that aborted rendering; log: {cut_log}")
                print("PASS: ten document-end cut/undo cycles preserve the unselected prefix")
                x11.tap(0xFF1B)
                wait_for_exit(process, args.timeout, cut_log)
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
        if clipboard_owner is not None:
            clipboard_owner.stop()
        if x11 is not None:
            x11.close()
        if succeeded:
            print(f"mouse X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
