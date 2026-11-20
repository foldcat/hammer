#!/usr/bin/env python3
"""Real X11 built-in window/file command tests for M08.09."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import time

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "typing"))
from x11_harness import HarnessFailure, X11, wait_for_exit  # noqa: E402


class ClientMessageData(ctypes.Union):
    _fields_ = [("b", ctypes.c_char * 20), ("s", ctypes.c_short * 10), ("l", ctypes.c_long * 5)]


class ClientMessageEvent(ctypes.Structure):
    _fields_ = [
        ("type", ctypes.c_int),
        ("serial", ctypes.c_ulong),
        ("send_event", ctypes.c_int),
        ("display", ctypes.c_void_p),
        ("window", ctypes.c_ulong),
        ("message_type", ctypes.c_ulong),
        ("format", ctypes.c_int),
        ("data", ClientMessageData),
    ]


class XEvent(ctypes.Union):
    _fields_ = [("client", ClientMessageEvent), ("pad", ctypes.c_long * 24)]


def request_close(x11: X11, window: int) -> None:
    x11.lib.XInternAtom.argtypes = [ctypes.c_void_p, ctypes.c_char_p, ctypes.c_int]
    x11.lib.XInternAtom.restype = ctypes.c_ulong
    x11.lib.XSendEvent.argtypes = [
        ctypes.c_void_p,
        ctypes.c_ulong,
        ctypes.c_int,
        ctypes.c_long,
        ctypes.POINTER(XEvent),
    ]
    protocols = x11.lib.XInternAtom(x11.display, b"WM_PROTOCOLS", 0)
    delete = x11.lib.XInternAtom(x11.display, b"WM_DELETE_WINDOW", 0)
    event = XEvent()
    event.client.type = 33
    event.client.display = x11.display
    event.client.window = window
    event.client.message_type = protocols
    event.client.format = 32
    event.client.data.l[0] = delete
    event.client.data.l[1] = 0
    x11.lib.XSendEvent(x11.display, window, 0, 0, ctypes.byref(event))
    x11.lib.XSync(x11.display, 0)


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
    parser.add_argument("--job-helper", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name an executable")
    job_helper = args.job_helper.resolve()
    if not job_helper.is_file():
        parser.error("--job-helper must name an executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m08-09-builtins-"))
    source = sandbox / "source.txt"
    second = sandbox / "second.txt"
    other = sandbox / "other.txt"
    pipe_source = sandbox / "pipe.txt"
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
        environment["HAMMER_TEST_IGNORE_JOB"] = str(job_helper)
        environment["HAMMER_TEST_FLOOD_JOB"] = str(job_helper)
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
            wait_for_log(log_path, "job: test helper started", args.timeout)
            job_match = re.search(r"job: test helper started id=\d+ process=(\d+)", log_path.read_text(encoding="utf-8"))
            if job_match is None:
                raise HarnessFailure("could not determine the test job PID")
            job_pid = int(job_match.group(1))
            flood_match = re.search(r"job: flood test helper started id=(\d+) process=(\d+)", log_path.read_text(encoding="utf-8"))
            if flood_match is None:
                raise HarnessFailure("could not determine the flood job ID")
            flood_id = int(flood_match.group(1))

            def run(command: str, x: int, y: int) -> None:
                name = command.split()[0]
                counts[name] = counts.get(name, 0) + 1
                execute(x11, window, command, x, y, args.timeout, log_path, counts[name])

            run("Newcol", 10, 10)
            wait_for_log(log_path, "view: Newcol column=3 window=5", args.timeout)
            print("PASS: Newcol creates a column and an empty window")

            click(x11, window, 1, 540, 100)
            run("New second.txt", 10, 10)
            wait_for_log(log_path, "view: New window=6 buffer=6", args.timeout)
            click(x11, window, 1, 540, 350)
            run("Zerox", 10, 10)
            wait_for_log(log_path, "view: Zerox window=7 buffer=6 from=6", args.timeout)
            append_text(x11, window, 540, 500, "!")
            click(x11, window, 1, 60, 100)
            run("New", 10, 10)
            wait_for_log(log_path, "view: New window=8", args.timeout)
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
            wait_for_log(log_path, "view: deleted column 3; 2 columns and 5 views remain", args.timeout)
            print("PASS: Delcol removes the invoking column after its buffers become clean")

            wait_for_log(log_path, f"job: released id={flood_id}", args.timeout)
            print("PASS: flood output drains through the job output window")

            request_close(x11, window)
            wait_for_log(log_path, "job: quit blocked on 1 job(s)", args.timeout)
            run("Wait", 10, 10)
            wait_for_log(log_path, "job: quit waiting for jobs and output to complete", args.timeout)
            click(x11, window, 1, 60, 100)
            type_text(x11, "x")
            wait_for_log(log_path, "job: quit canceled (origin=OS_Close)", args.timeout)
            time.sleep(0.3)
            if process.poll() is not None:
                raise HarnessFailure("editing did not cancel the pending job quit")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            print("PASS: Wait keeps the editor open and ordinary editing cancels exit")

            request_close(x11, window)
            wait_for_log(log_path, "job: quit blocked on 1 job(s)", args.timeout, 2)
            run("Stop", 10, 10)
            wait_for_log(log_path, "job: Stop requested for 1 job(s) during quit", args.timeout)
            stop_deadline = time.monotonic() + args.timeout
            while Path(f"/proc/{job_pid}").exists() and time.monotonic() < stop_deadline:
                time.sleep(0.05)
            if Path(f"/proc/{job_pid}").exists():
                raise HarnessFailure(f"Stop did not reap test job {job_pid}")
            wait_for_exit(process, args.timeout, log_path)
            process = None
            print("PASS: Stop cancels and reaps running jobs before resuming quit")

            pipe_source.write_bytes("pipe α β\n".encode("utf-8"))
            pipe_log_path = sandbox / "pipe-hammer.log"
            pipe_environment = environment.copy()
            pipe_environment.pop("HAMMER_TEST_IGNORE_JOB")
            pipe_environment.pop("HAMMER_TEST_FLOOD_JOB")
            pipe_environment["HAMMER_TEST_PIPE_JOB"] = str(job_helper)
            pipe_environment["HAMMER_TEST_PIPE_DELAY"] = "1"
            pipe_environment["XDG_STATE_HOME"] = str(sandbox / "pipe-state")
            with pipe_log_path.open("wb") as pipe_log:
                process = subprocess.Popen(
                    [str(binary), "pipe.txt"],
                    cwd=sandbox,
                    stdin=subprocess.DEVNULL,
                    stdout=pipe_log,
                    stderr=subprocess.STDOUT,
                    env=pipe_environment,
                )
                pipe_window = x11.find_window(args.timeout)
                x11.lib.XMapRaised(x11.display, pipe_window)
                x11.lib.XSetInputFocus(x11.display, pipe_window, 1, 0)
                x11.lib.XSync(x11.display, 0)
                wait_for_log(pipe_log_path, "job: selection test helper started", args.timeout)
                x11.tap(0xFF1B)
                wait_for_log(pipe_log_path, "job: quit blocked on 1 job(s)", args.timeout)
                execute(x11, pipe_window, "Wait", 10, 10, args.timeout, pipe_log_path, 1)
                wait_for_log(pipe_log_path, "job: selection replaced", args.timeout)
                wait_for_log(pipe_log_path, "edit: unsaved text; close blocked", args.timeout)
                time.sleep(0.3)
                if process.poll() is not None:
                    raise HarnessFailure("job completion bypassed the dirty-buffer quit review")
                execute(x11, pipe_window, "Putall", 10, 10, args.timeout, pipe_log_path, 1)
                wait_for_log(pipe_log_path, "file: saved pipe.txt", args.timeout)
                if pipe_source.read_bytes() != "filtered:pipe α β\n".encode("utf-8"):
                    raise HarnessFailure(f"selection pipe wrote unexpected bytes: {pipe_source.read_bytes()!r}")
                print("PASS: Wait drains selection output and still enforces the dirty-buffer quit review")
                x11.tap(0xFF1B)
                wait_for_exit(process, args.timeout, pipe_log_path)
                process = None

            pipe_source.write_bytes("pipe α β\n".encode("utf-8"))
            conflict_log_path = sandbox / "pipe-conflict-hammer.log"
            conflict_environment = pipe_environment.copy()
            conflict_environment["HAMMER_TEST_PIPE_DELAY"] = "1"
            conflict_environment["XDG_STATE_HOME"] = str(sandbox / "pipe-conflict-state")
            with conflict_log_path.open("wb") as conflict_log:
                process = subprocess.Popen(
                    [str(binary), "pipe.txt"],
                    cwd=sandbox,
                    stdin=subprocess.DEVNULL,
                    stdout=conflict_log,
                    stderr=subprocess.STDOUT,
                    env=conflict_environment,
                )
                conflict_window = x11.find_window(args.timeout)
                x11.lib.XMapRaised(x11.display, conflict_window)
                x11.lib.XSetInputFocus(x11.display, conflict_window, 1, 0)
                x11.lib.XSync(x11.display, 0)
                wait_for_log(conflict_log_path, "job: selection test helper started", args.timeout)
                click(x11, conflict_window, 1, 60, 100)
                select_all(x11)
                type_text(x11, "newer")
                wait_for_log(conflict_log_path, "job: selection conflict preserved", args.timeout)
                if "job: selection replaced" in conflict_log_path.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("conflicted selection output replaced newer edits")
                execute(x11, conflict_window, "Putall", 10, 10, args.timeout, conflict_log_path, 1)
                wait_for_log(conflict_log_path, "file: saved pipe.txt", args.timeout, 1)
                if pipe_source.read_bytes() != b"newer":
                    raise HarnessFailure(f"conflict did not preserve newer edits: {pipe_source.read_bytes()!r}")
                execute(x11, conflict_window, "Apply", 540, 330, args.timeout, conflict_log_path, 1)
                wait_for_log(conflict_log_path, "job: selection conflict applied", args.timeout)
                execute(x11, conflict_window, "Putall", 10, 10, args.timeout, conflict_log_path, 2)
                wait_for_log(conflict_log_path, "file: saved pipe.txt", args.timeout, 2)
                expected = "newerfiltered:pipe α β\n".encode("utf-8")
                if pipe_source.read_bytes() != expected:
                    raise HarnessFailure(f"explicit Apply wrote unexpected bytes: {pipe_source.read_bytes()!r}")
                print("PASS: conflicted output preserves newer edits and Apply uses the current selection")
                x11.tap(0xFF1B)
                wait_for_exit(process, args.timeout, conflict_log_path)
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
