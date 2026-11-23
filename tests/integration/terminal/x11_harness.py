#!/usr/bin/env python3
"""Real X11 terminal (`Win`) smoke test for M10.06 slice 2.

Validates that `Win` opens a PTY-backed terminal window, that typing and native
clipboard paste reach the shell, and that the shell's output and exit are
decoded and reaped end to end.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import ClipboardOwner, HarnessFailure, X11, wait_for_exit  # noqa: E402


def click(x11: X11, window: int, button: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(button, True)
    x11.button(button, False)


def select_all(x11: X11) -> None:
    x11.key(0xFFE3, True)
    x11.tap(ord("a"))
    x11.key(0xFFE3, False)


def type_text(x11: X11, text: str) -> None:
    for character in text:
        if character.isupper() or character == "!":
            x11.key(0xFFE1, True)
            x11.tap(ord(character.lower()))
            x11.key(0xFFE1, False)
        else:
            x11.tap(ord(character))


def wait_for_log(log_path: Path, needle: str, timeout: float, occurrence: int = 1) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.read_text(encoding="utf-8", errors="replace").count(needle) >= occurrence:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r}; log: {log_path}")


def execute(x11: X11, window: int, command: str, x: int, y: int, timeout: float, log_path: Path) -> None:
    click(x11, window, 1, x, y)
    select_all(x11)
    type_text(x11, command)
    select_all(x11)
    click(x11, window, 2, x, y)
    wait_for_log(log_path, f'mouse: execute "{command.split()[0]}"', timeout)


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m10-06-terminal-"))
    source = sandbox / "source.txt"
    source.write_bytes(b"alpha\n")
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    clipboard_owner: ClipboardOwner | None = None
    x11: X11 | None = None
    succeeded = False
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary), source.name],
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
            wait_for_log(log_path, "file: opened source.txt", args.timeout)

            execute(x11, window, "Win", 10, 10, args.timeout, log_path)
            wait_for_log(log_path, "terminal: opened", args.timeout)
            print("PASS: Win opens a PTY-backed terminal window")

            # M10.07e: the terminal spawns the system default shell ($SHELL),
            # not /bin/sh. The open log records the resolved shell verbatim.
            expected_shell = os.environ.get("SHELL") or "sh"
            wait_for_log(log_path, f'shell="{expected_shell}"', args.timeout)
            print(f"PASS: the terminal spawns the system default shell ({expected_shell})")

            wait_for_log(log_path, "terminal: resize", args.timeout)
            print("PASS: the terminal grid resizes to the window (SIGWINCH)")

            pasted_command = "printf terminal-paste-ok > terminal-paste-result"
            pasted_path = sandbox / "external-terminal-paste.txt"
            pasted_path.write_text(pasted_command, encoding="utf-8")
            clipboard_owner = ClipboardOwner(clipboard_peer, pasted_path, sandbox, args.timeout)
            x11.key(0xFFE3, True)
            x11.key(0xFFE1, True)
            x11.tap(ord("v"))
            x11.key(0xFFE1, False)
            x11.key(0xFFE3, False)
            wait_for_log(log_path, "terminal: pasted", args.timeout)
            x11.tap(0xFF0D)
            paste_result = sandbox / "terminal-paste-result"
            deadline = time.monotonic() + args.timeout
            while not paste_result.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            if not paste_result.exists() or paste_result.read_bytes() != b"terminal-paste-ok":
                raise HarnessFailure(f"Ctrl+Shift+V did not paste the external clipboard into the terminal; log: {log_path}")
            clipboard_owner.stop()
            clipboard_owner = None
            print("PASS: Ctrl+Shift+V pastes the native clipboard into the terminal")

            type_text(x11, "echo terminal-ok")
            x11.tap(0xFF0D)
            time.sleep(0.4)
            type_text(x11, "printf '\\033[31mCOLOR\\033[0m\\n'")
            x11.tap(0xFF0D)
            time.sleep(0.4)
            # Generate enough output to scroll into the scrollback, exercising
            # the incremental append path (M10.07d).
            type_text(x11, "seq 1 300")
            x11.tap(0xFF0D)
            time.sleep(0.8)
            type_text(x11, "clear")
            x11.tap(0xFF0D)
            time.sleep(0.4)
            type_text(x11, "exit")
            x11.tap(0xFF0D)
            wait_for_log(log_path, "terminal: exited", args.timeout)
            print("PASS: typing reaches the shell and its exit is reaped")

            log_text = log_path.read_text(encoding="utf-8", errors="replace")
            match = re.search(r"terminal: exited buffer=\d+ code=\d+ signal=\d+ bytes=(\d+)", log_text)
            if match is None:
                raise HarnessFailure(f"terminal exit log lacks a byte count; log: {log_path}")
            if int(match.group(1)) < 20:
                raise HarnessFailure(
                    f"terminal buffer has only {match.group(1)} bytes; expected the shell's echo output; log: {log_path}"
                )
            print("PASS: the terminal buffer received the shell's output")

            if shutil.which("raku") is not None:
                execute(x11, window, "RakuRepl", 10, 10, args.timeout, log_path)
                wait_for_log(log_path, "raku: REPL opened", args.timeout)
                wait_for_log(log_path, "terminal: resize", args.timeout, 2)
                type_text(x11, 'say 6*7; spurt "raku-repl-ok", 42')
                x11.tap(0xFF0D)
                repl_marker = sandbox / "raku-repl-ok"
                deadline = time.monotonic() + args.timeout
                while not repl_marker.exists() and time.monotonic() < deadline:
                    time.sleep(0.05)
                if repl_marker.read_bytes() != b"42":
                    raise HarnessFailure("Raku REPL did not evaluate typed input")
                type_text(x11, "exit")
                x11.tap(0xFF0D)
                wait_for_log(log_path, "terminal: exited", args.timeout, 2)
                print("PASS: RakuRepl evaluates typed one-liners in a PTY window and exits cleanly")
            else:
                print("SKIP: RakuRepl execution (raku is not installed)")

            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None
        succeeded = True
        print("PASS: all X11 terminal checks")
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
            for path in sandbox.iterdir():
                path.unlink()
            sandbox.rmdir()


if __name__ == "__main__":
    raise SystemExit(main())
