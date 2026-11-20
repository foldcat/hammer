#!/usr/bin/env python3
"""Real X11 terminal (`Win`) smoke test for M10.06 slice 2.

Validates that `Win` opens a PTY-backed terminal window, that typing reaches
the shell (input forwarding), and that the shell's output and exit are decoded
and reaped end to end.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402


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
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name an executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m10-06-terminal-"))
    source = sandbox / "source.txt"
    source.write_bytes(b"alpha\n")
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

            type_text(x11, "echo terminal-ok")
            x11.tap(0xFF0D)
            time.sleep(0.4)
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
