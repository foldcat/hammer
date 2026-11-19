#!/usr/bin/env python3
"""Real X11 Edit command dispatch and transaction smoke tests for M08.04."""

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


def wait_for_log(log_path: Path, needle: str, timeout: float, occurrence: int = 1) -> None:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if log_path.read_text(encoding="utf-8", errors="replace").count(needle) >= occurrence:
            return
        time.sleep(0.05)
    raise HarnessFailure(f"timed out waiting for {needle!r} occurrence {occurrence}; log: {log_path}")


def click(x11: X11, window: int, button: int, x: int, y: int) -> None:
    x11.move(window, x, y)
    x11.button(button, True)
    x11.button(button, False)


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m08-04-edit-"))
    source = sandbox / "a"
    source.write_bytes(b"one\ntwo\nthree\n")
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    x11: X11 | None = None
    succeeded = False
    command_counts: dict[str, int] = {}
    save_count = 0
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary), "a"],
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
            wait_for_log(log_path, "file: opened a", args.timeout)

            def execute(command: str, prefix_length: int = 8) -> None:
                nonlocal save_count
                click(x11, window, 1, 350, 52)
                for character in command:
                    if character.isupper():
                        x11.key(0xFFE1, True)
                        x11.tap(ord(character.lower()))
                        x11.key(0xFFE1, False)
                    else:
                        x11.tap(ord(character))
                x11.key(0xFFE1, True)
                x11.tap(0xFF50)
                for _ in range(prefix_length):
                    x11.tap(0xFF53)
                x11.key(0xFFE1, False)
                x11.key(0xFFE3, True)
                x11.tap(0xFF0D)
                x11.key(0xFFE3, False)
                name = command.split()[0]
                command_counts[name] = command_counts.get(name, 0) + 1
                wait_for_log(log_path, f'mouse: execute "{name}"', args.timeout, command_counts[name])
                x11.key(0xFFE3, True)
                x11.tap(ord("s"))
                x11.key(0xFFE3, False)
                save_count += 1
                wait_for_log(log_path, "file: saved ", args.timeout, save_count)
                x11.tap(0xFF08)
                time.sleep(0.1)

            execute("Edit 1c/X\\nY\\n/")
            if source.read_bytes() != b"X\nY\ntwo\nthree\n":
                raise HarnessFailure(f"Edit change produced {source.read_bytes()!r}")
            print("PASS: Ctrl+Enter Edit applies escaped text through the window body")

            execute("Edit 2d")
            if source.read_bytes() != b"X\ntwo\nthree\n":
                raise HarnessFailure(f"Edit delete produced {source.read_bytes()!r}")
            print("PASS: addressed Edit delete saves the expected bytes")

            execute("Undo")
            if source.read_bytes() != b"X\nY\ntwo\nthree\n":
                raise HarnessFailure(f"Undo after Edit produced {source.read_bytes()!r}")
            print("PASS: Undo restores the complete Edit transaction")

            execute("Edit 2,3m0")
            if source.read_bytes() != b"Y\ntwo\nX\nthree\n":
                raise HarnessFailure(f"Edit move produced {source.read_bytes()!r}")
            print("PASS: Edit move uses original-snapshot transaction ordering")

            execute("Undo")
            if source.read_bytes() != b"X\nY\ntwo\nthree\n":
                raise HarnessFailure(f"Undo after move produced {source.read_bytes()!r}")
            print("PASS: move is coherently undoable")

            x11.tap(0xFF1B)
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
            print(f"Edit X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
