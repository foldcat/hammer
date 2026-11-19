#!/usr/bin/env python3
"""Real X11 built-in window/file command tests for M08.09."""

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


def execute(x11: X11, window: int, command: str, x: int, y: int, timeout: float, log_path: Path, count: int) -> None:
    click(x11, window, 1, x, y)
    select_all(x11)
    type_text(x11, command)
    select_all(x11)
    click(x11, window, 2, x, y)
    name = command.split()[0]
    wait_for_log(log_path, f'mouse: execute "{name}"', timeout, count)


def append_text(x11: X11, window: int, x: int, y: int, text: str) -> None:
    click(x11, window, 1, x, y)
    x11.key(0xFFE3, True)
    x11.tap(0xFF57)
    x11.key(0xFFE3, False)
    type_text(x11, text)


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

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m08-09-builtins-"))
    source = sandbox / "source.txt"
    second = sandbox / "second.txt"
    other = sandbox / "other.txt"
    source.write_bytes(b"alpha\n")
    second.write_bytes(b"second\n")
    other.write_bytes(b"other\n")
    log_path = sandbox / "hammer.log"
    process: subprocess.Popen[bytes] | None = None
    x11: X11 | None = None
    succeeded = False
    counts: dict[str, int] = {}
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary), "source.txt"],
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

            def run(command: str, x: int, y: int) -> None:
                name = command.split()[0]
                counts[name] = counts.get(name, 0) + 1
                execute(x11, window, command, x, y, args.timeout, log_path, counts[name])

            run("Newcol", 10, 10)
            wait_for_log(log_path, "view: Newcol column=3 window=3", args.timeout)
            print("PASS: Newcol creates a column and an empty window")

            click(x11, window, 1, 540, 100)
            run("New second.txt", 10, 10)
            wait_for_log(log_path, "view: New window=4 buffer=4", args.timeout)
            click(x11, window, 1, 540, 350)
            run("Zerox", 10, 10)
            wait_for_log(log_path, "view: Zerox window=5 buffer=4 from=4", args.timeout)
            append_text(x11, window, 540, 500, "!")
            click(x11, window, 1, 60, 100)
            run("New", 10, 10)
            wait_for_log(log_path, "view: New window=6", args.timeout)
            print("PASS: New creates empty and named-file windows; Zerox shares the named buffer")

            click(x11, window, 2, 600, 30)
            wait_for_log(log_path, "view: column has unsaved text; deletion blocked", args.timeout)
            if "view: deleted column" in log_path.read_text(encoding="utf-8", errors="replace"):
                raise HarnessFailure("Delcol removed a column with unsaved text")
            print("PASS: Delcol rejects the whole column while a buffer is dirty")

            click(x11, window, 1, 60, 100)
            source.write_bytes(b"external\n")
            run("Get", 60, 52)
            wait_for_log(log_path, "file: reloaded source.txt", args.timeout, 1)
            append_text(x11, window, 60, 100, "x")
            source.write_bytes(b"newer\n")
            run("Get", 60, 52)
            wait_for_log(log_path, "has unsaved text; reload blocked", args.timeout)
            if source.read_bytes() != b"newer\n":
                raise HarnessFailure("dirty Get changed the file on disk")
            click(x11, window, 1, 60, 100)
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            run("Get", 60, 52)
            wait_for_log(log_path, "file: reloaded source.txt", args.timeout, 2)
            run("Get other.txt", 60, 52)
            wait_for_log(log_path, "file: reloaded ", args.timeout, 3)
            append_text(x11, window, 60, 100, "!")
            print("PASS: Get reloads clean buffers, blocks dirty replacement, and accepts another path")

            run("Putall", 10, 10)
            wait_for_log(log_path, "file: saved source.txt", args.timeout)
            wait_for_log(log_path, f"file: saved {second}", args.timeout)
            if source.read_bytes() != b"other\n!":
                raise HarnessFailure(f"Putall wrote unexpected source bytes: {source.read_bytes()!r}")
            if second.read_bytes() != b"second\n!":
                raise HarnessFailure(f"Putall wrote unexpected Zerox buffer bytes: {second.read_bytes()!r}")
            if log_path.read_text(encoding="utf-8", errors="replace").count(f"file: saved {second}") != 1:
                raise HarnessFailure("Putall saved a shared buffer more than once")
            print("PASS: Putall saves every dirty named regular-file buffer once")

            click(x11, window, 2, 600, 30)
            wait_for_log(log_path, 'mouse: execute "Delcol"', args.timeout)
            wait_for_log(log_path, "view: deleted column 3; 2 columns and 3 views remain", args.timeout)
            print("PASS: Delcol removes the invoking column after its buffers become clean")

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
            print(f"Built-in command X11 smoke passed; sandbox: {sandbox}")


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except HarnessFailure as error:
        print(f"FAIL: {error}", file=sys.stderr)
        raise SystemExit(1)
