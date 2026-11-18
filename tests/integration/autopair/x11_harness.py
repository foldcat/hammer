#!/usr/bin/env python3
"""Exercise the real product with compiled autopair enabled and disabled."""

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
from x11_harness import HarnessFailure, X11, read_external_clipboard, wait_for_exit


def copy_document(
    x11: X11,
    peer: Path,
    output: Path,
    timeout: float,
) -> bytes:
    x11.key(0xFFE3, True)
    x11.tap(ord("a"))
    x11.tap(ord("c"))
    x11.key(0xFFE3, False)
    time.sleep(0.3)
    read_external_clipboard(peer, output, timeout)
    return output.read_bytes()


def reset_document(x11: X11, window: int, initial: bytes, label: str) -> None:
    for _ in range(24):
        x11.key(0xFFE3, True)
        x11.tap(ord("z"))
        x11.key(0xFFE3, False)
        time.sleep(0.03)
    time.sleep(0.2)
    if x11.pixels(window) != initial:
        raise HarnessFailure(f"{label}: bounded undo sequence did not restore the empty document")


def run_case(
    x11: X11,
    binary: Path,
    peer: Path,
    label: str,
    sandbox: Path,
    timeout: float,
    empty_pair_result: bytes,
    newline_result: bytes,
    selection_result: bytes,
) -> None:
    process: subprocess.Popen[bytes] | None = None
    log_path = sandbox / f"hammer-{label}.log"
    try:
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / f"state-{label}")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary)],
                stdin=subprocess.DEVNULL,
                stdout=log,
                stderr=subprocess.STDOUT,
                env=environment,
            )
            window = x11.find_window(timeout)
            x11.lib.XMapRaised(x11.display, window)
            x11.lib.XSetInputFocus(x11.display, window, 1, 0)
            x11.lib.XSync(x11.display, 0)
            time.sleep(0.3)
            initial = x11.pixels(window)

            for keysym in (ord("("), ord(")"), 0xFF51, 0xFF08, ord("z")):
                x11.tap(keysym)
            time.sleep(0.3)
            actual = copy_document(x11, peer, sandbox / f"{label}-empty-pair.txt", timeout)
            if actual != empty_pair_result:
                raise HarnessFailure(
                    f"{label}: closing/Backspace policy produced {actual!r}, want {empty_pair_result!r}"
                )
            print(f"PASS: {label} product closing-delimiter and empty-pair Backspace policy")

            reset_document(x11, window, initial, label)
            for keysym in (ord("["), 0xFF0D):
                x11.tap(keysym)
            time.sleep(0.3)
            actual = copy_document(x11, peer, sandbox / f"{label}-newline.txt", timeout)
            if actual != newline_result:
                raise HarnessFailure(
                    f"{label}: pair newline produced {actual!r}, want {newline_result!r}"
                )
            print(f"PASS: {label} product pair-newline indentation policy")

            reset_document(x11, window, initial, label)
            for keysym in (ord("["), 0xFFFF, 0xFF0D):
                x11.tap(keysym)
            time.sleep(0.3)
            actual = copy_document(x11, peer, sandbox / f"{label}-opener-newline.txt", timeout)
            if actual != b"[\n\t":
                raise HarnessFailure(
                    f"{label}: opener newline produced {actual!r}, want an indented line after the opening bracket"
                )
            print(f"PASS: {label} product indents after an opening bracket without an adjacent closer")

            reset_document(x11, window, initial, label)
            for keysym in (ord("a"), 0xFF0D, ord(")")):
                x11.tap(keysym)
            x11.key(0xFFE3, True)
            x11.tap(0xFF50)
            x11.key(0xFFE3, False)
            x11.tap(ord("("))
            time.sleep(0.3)
            actual = copy_document(x11, peer, sandbox / f"{label}-multiline.txt", timeout)
            if actual != b"(a\n)":
                raise HarnessFailure(f"{label}: multiline closer reuse produced {actual!r}, want an opening parenthesis, a, newline, and one closing parenthesis")
            print(f"PASS: {label} product reuses an unmatched closing parenthesis on a later line")

            reset_document(x11, window, initial, label)
            for character in "abc":
                x11.tap(ord(character))
            x11.key(0xFFE3, True)
            x11.tap(ord("a"))
            x11.key(0xFFE3, False)
            for keysym in (ord("["), ord("x"), ord("'"), ord("'")):
                x11.tap(keysym)
            time.sleep(0.3)
            actual = copy_document(x11, peer, sandbox / f"{label}-selection.txt", timeout)
            if actual != selection_result:
                raise HarnessFailure(
                    f"{label}: selection/quote policy produced {actual!r}, want {selection_result!r}"
                )
            print(f"PASS: {label} product selection wrapping and quote policy")

            reset_document(x11, window, initial, label)
            x11.tap(0xFF1B)
            wait_for_exit(process, timeout, log_path)
            process = None
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)

    log_text = log_path.read_text(encoding="utf-8", errors="replace")
    expected_flag = f"autopair={'true' if label == 'enabled' else 'false'}"
    if expected_flag not in log_text:
        raise HarnessFailure(f"{label}: product did not use its staged autopair config; log: {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--enabled", required=True, type=Path)
    parser.add_argument("--disabled", required=True, type=Path)
    parser.add_argument("--clipboard-peer", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    enabled = args.enabled.resolve()
    disabled = args.disabled.resolve()
    peer = args.clipboard_peer.resolve()
    if not enabled.is_file() or not disabled.is_file() or not peer.is_file():
        parser.error("--enabled, --disabled, and --clipboard-peer must name executables")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m06-13-autopair-"))
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        run_case(x11, enabled, peer, "enabled", sandbox, args.timeout, b"z", b"[\n\t\n]", b"[x'']")
        run_case(x11, disabled, peer, "disabled", sandbox, args.timeout, b"z)", b"[\n\t", b"[x''")
        succeeded = True
        print("PASS: compiled autopair configuration controls real product editing")
        return 0
    except (HarnessFailure, OSError) as error:
        print(f"FAIL: {error}; preserved sandbox: {sandbox}", file=sys.stderr)
        return 1
    finally:
        if x11 is not None:
            x11.close()
        if succeeded:
            shutil.rmtree(sandbox)


if __name__ == "__main__":
    raise SystemExit(main())
