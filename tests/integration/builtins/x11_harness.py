#!/usr/bin/env python3
"""Real X11 built-in window/file command tests for M08.09."""

from __future__ import annotations

import argparse
import ctypes
import os
from pathlib import Path
import re
import shutil
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
    shifted = {"+": "=", "$": "4", "*": "8", '"': "'"}
    for character in text:
        if character in shifted:
            x11.key(0xFFE1, True)
            x11.tap(ord(shifted[character]))
            x11.key(0xFFE1, False)
        elif character.isupper() or character == "!":
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


def type_pipe_text(x11: X11, text: str) -> None:
    """Types text including the pipe routing prefixes that need Shift."""
    for character in text:
        if character == "|":
            x11.key(0xFFE1, True)
            x11.tap(ord("\\"))
            x11.key(0xFFE1, False)
        elif character == "<":
            x11.key(0xFFE1, True)
            x11.tap(ord(","))
            x11.key(0xFFE1, False)
        elif character == ">":
            x11.key(0xFFE1, True)
            x11.tap(ord("."))
            x11.key(0xFFE1, False)
        elif character == "_":
            x11.key(0xFFE1, True)
            x11.tap(ord("-"))
            x11.key(0xFFE1, False)
        elif character.isupper() or character == "!":
            x11.key(0xFFE1, True)
            x11.tap(ord(character.lower()))
            x11.key(0xFFE1, False)
        else:
            x11.tap(ord(character))


def execute_pipe(x11: X11, window: int, command: str) -> None:
    """Types and executes a pipe command in the window tag (no log wait)."""
    click(x11, window, 1, 60, 52)
    select_all(x11)
    type_pipe_text(x11, command)
    select_all(x11)
    click(x11, window, 2, 60, 52)


def run_external_case(
    args: argparse.Namespace,
    binary: Path,
    sandbox: Path,
    x11: X11,
    job_helper: Path,
    command: str,
    body: str,
    route_name: str,
    content: bytes,
    expect_replace: bool,
) -> tuple[bytes, str]:
    """Runs one synchronous external command in a fresh editor and returns the
    file bytes and the log text."""
    source = sandbox / f"route-{route_name}.txt"
    source.write_bytes(content)
    log_path = sandbox / f"route-{route_name}-hammer.log"
    environment = os.environ.copy()
    environment["HAMMER_LOG"] = ""
    environment["PATH"] = f"{job_helper.parent}{os.pathsep}{environment.get('PATH', '')}"
    environment["XDG_STATE_HOME"] = str(sandbox / f"route-{route_name}-state")
    process: subprocess.Popen[bytes] | None = None
    try:
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
            # Select the whole body as the pipe input/target.
            click(x11, window, 1, 60, 100)
            select_all(x11)
            execute_pipe(x11, window, command)
            wait_for_log(log_path, f'mouse: execute "{body}" routing={route_name} async=false', args.timeout)
            if expect_replace:
                wait_for_log(log_path, "shell: selection replaced", args.timeout)
                execute(x11, window, "Putall", 10, 10, args.timeout, log_path, 1)
                wait_for_log(log_path, f"file: saved {source.name}", args.timeout)
            else:
                wait_for_log(log_path, "errors: opened", args.timeout)
                if "shell: selection replaced" in log_path.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure(f"{command!r} replaced the selection instead of writing +Errors")
            x11.quit()
            wait_for_exit(process, args.timeout, log_path)
            process = None
            return source.read_bytes(), log_path.read_text(encoding="utf-8", errors="replace")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def run_async_case(
    args: argparse.Namespace,
    binary: Path,
    sandbox: Path,
    x11: X11,
    job_helper: Path,
    command: str,
    body: str,
) -> bytes:
    """Runs one `Async` pipe command in a fresh editor and returns the file bytes."""
    source = sandbox / "route-async.txt"
    content = "async α β\n".encode("utf-8")
    source.write_bytes(content)
    log_path = sandbox / "route-async-hammer.log"
    environment = os.environ.copy()
    environment["HAMMER_LOG"] = ""
    environment["PATH"] = f"{job_helper.parent}{os.pathsep}{environment.get('PATH', '')}"
    environment["XDG_STATE_HOME"] = str(sandbox / "route-async-state")
    process: subprocess.Popen[bytes] | None = None
    try:
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
            click(x11, window, 1, 60, 100)
            select_all(x11)
            execute_pipe(x11, window, command)
            wait_for_log(log_path, f'mouse: execute "{body}" routing=pipe async=true', args.timeout)
            wait_for_log(log_path, "shell: started async pipe id=", args.timeout)
            wait_for_log(log_path, "job: selection replaced", args.timeout)
            execute(x11, window, "Putall", 10, 10, args.timeout, log_path, 1)
            wait_for_log(log_path, f"file: saved {source.name}", args.timeout)
            x11.quit()
            wait_for_exit(process, args.timeout, log_path)
            process = None
            return source.read_bytes()
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


def run_regex_case(
    args: argparse.Namespace,
    binary: Path,
    sandbox: Path,
    x11: X11,
    external: bool,
) -> str:
    name = "external" if external else "native"
    source = sandbox / f"regex-{name}.txt"
    source.write_bytes("zero\nneedle one\nαβ🙂 needle two\n".encode("utf-8"))
    log_path = sandbox / f"regex-{name}-hammer.log"
    environment = os.environ.copy()
    environment["HAMMER_LOG"] = ""
    environment["XDG_CONFIG_HOME"] = str(sandbox / f"regex-{name}-config")
    environment["XDG_STATE_HOME"] = str(sandbox / f"regex-{name}-state")
    for variable in ("HAMMER_TEST_IGNORE_JOB", "HAMMER_TEST_FLOOD_JOB", "HAMMER_TEST_PIPE_JOB", "HAMMER_TEST_PIPE_DELAY"):
        environment.pop(variable, None)
    if not external:
        empty_path = sandbox / "regex-empty-path"
        empty_path.mkdir()
        environment["PATH"] = str(empty_path)
    process: subprocess.Popen[bytes] | None = None
    try:
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
            click(x11, window, 1, 60, 100)
            select_all(x11)
            execute(x11, window, "Raku /needle/", 60, 52, args.timeout, log_path, 1)
            if external:
                wait_for_log(log_path, 'regex: echo "/needle/"', args.timeout)
                wait_for_log(log_path, "regex: external search started", args.timeout)
                wait_for_log(log_path, "regex: external match id=", args.timeout)
                wait_for_log(log_path, "range=5,11", args.timeout)
                execute(x11, window, "Raku /needle/", 60, 52, args.timeout, log_path, 2)
                wait_for_log(log_path, "range=25,31", args.timeout)
                execute(x11, window, "Raku /needle/", 60, 52, args.timeout, log_path, 3)
                wait_for_log(log_path, "range=5,11", args.timeout, 2)
                if "errors: opened" in log_path.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("external Raku search opened a redundant +Errors window")
            else:
                wait_for_log(log_path, "regex: native fallback", args.timeout)
                wait_for_log(log_path, "range=5,11", args.timeout)
                if "regex: external search started" in log_path.read_text(encoding="utf-8", errors="replace"):
                    raise HarnessFailure("native fallback unexpectedly spawned Raku")
            x11.quit()
            wait_for_exit(process, args.timeout, log_path)
            process = None
            return log_path.read_text(encoding="utf-8", errors="replace")
    finally:
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=2)


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
                x11.quit()
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
                x11.quit()
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
                x11.quit()
                wait_for_exit(process, args.timeout, conflict_log_path)
                process = None

            config_home = sandbox / "config"
            user_commands = config_home / "hammer" / "commands"
            project_commands = sandbox / ".hammer" / "commands"
            user_commands.mkdir(parents=True)
            project_commands.mkdir(parents=True)
            marker = sandbox / "filter-body-executed"
            body = f"touch {marker}"
            (user_commands / "shared.filter").write_text(
                f"name: shared-filter\nengine: {job_helper.name}\nrouting: discard\nbody: {body}\n",
                encoding="utf-8",
            )
            (project_commands / "shared.filter").write_text(
                f"name: shared-filter\nengine: missing-m09-engine\nrouting: output-window\nbody: {body}\n",
                encoding="utf-8",
            )
            filter_log_path = sandbox / "filter-hammer.log"
            filter_environment = pipe_environment.copy()
            for variable in ("HAMMER_TEST_IGNORE_JOB", "HAMMER_TEST_FLOOD_JOB", "HAMMER_TEST_PIPE_JOB", "HAMMER_TEST_PIPE_DELAY"):
                filter_environment.pop(variable, None)
            filter_environment["XDG_CONFIG_HOME"] = str(config_home)
            filter_environment["XDG_STATE_HOME"] = str(sandbox / "filter-state")
            filter_environment["PATH"] = f"{job_helper.parent}{os.pathsep}{filter_environment['PATH']}"
            with filter_log_path.open("wb") as filter_log:
                process = subprocess.Popen(
                    [str(binary), "source.txt"],
                    cwd=sandbox,
                    stdin=subprocess.DEVNULL,
                    stdout=filter_log,
                    stderr=subprocess.STDOUT,
                    env=filter_environment,
                )
                filter_window = x11.find_window(args.timeout)
                x11.lib.XMapRaised(x11.display, filter_window)
                x11.lib.XSetInputFocus(x11.display, filter_window, 1, 0)
                x11.lib.XSync(x11.display, 0)
                wait_for_log(filter_log_path, "filter: loaded user definitions", args.timeout)
                execute(x11, filter_window, "Cmds", 10, 10, args.timeout, filter_log_path, 1)
                wait_for_log(filter_log_path, "filter: listed 1 definitions (1 engines available)", args.timeout)
                execute(x11, filter_window, "Cmd project", 10, 10, args.timeout, filter_log_path, 1)
                wait_for_log(filter_log_path, "filter: explicitly trusting project definitions", args.timeout)
                wait_for_log(filter_log_path, "filter: listed 2 definitions (1 engines available)", args.timeout)
                if marker.exists():
                    raise HarnessFailure("command discovery executed a filter body")
                print("PASS: Cmd/Cmds enumerates trusted user and explicit project definitions without execution")
                x11.quit()
                wait_for_exit(process, args.timeout, filter_log_path)
                process = None

            # M09.10: named-filter invocation with context snapshot, routing, and echo.
            invoke_config_home = sandbox / "invoke-config"
            invoke_user_commands = invoke_config_home / "hammer" / "commands"
            invoke_user_commands.mkdir(parents=True)
            (invoke_user_commands / "invoke-pipe.filter").write_text(
                f"name: invoke-pipe\nengine: {job_helper.name}\nrouting: replace-selection\nbody: pipe\n",
                encoding="utf-8",
            )
            (invoke_user_commands / "invoke-out.filter").write_text(
                f"name: invoke-out\nengine: {job_helper.name}\nrouting: output-window\nbody: pipe\n",
                encoding="utf-8",
            )
            (invoke_user_commands / "invoke-discard.filter").write_text(
                f"name: invoke-discard\nengine: {job_helper.name}\nrouting: discard\nbody: mark\n",
                encoding="utf-8",
            )
            if shutil.which("raku") is not None:
                (invoke_user_commands / "raku-upper.filter").write_text(
                    "name: raku-upper\nengine: raku\nrouting: replace-selection\nraku: -p\nbody: $_ = $_.uc\n",
                    encoding="utf-8",
                )
                (invoke_user_commands / "raku-lines.filter").write_text(
                    'name: raku-lines\nengine: raku\nrouting: output-window\nraku: -n\nbody: spurt "raku-n-ok", $_\n',
                    encoding="utf-8",
                )
            invoke_source = sandbox / "invoke.txt"
            invoke_source.write_bytes("invoke α β\n".encode("utf-8"))
            discard_marker = sandbox / "discard-marker.txt"
            invoke_log_path = sandbox / "invoke-hammer.log"
            invoke_environment = filter_environment.copy()
            invoke_environment["XDG_CONFIG_HOME"] = str(invoke_config_home)
            invoke_environment["XDG_STATE_HOME"] = str(sandbox / "invoke-state")
            raku_temp = sandbox / "raku-temp"
            raku_temp.mkdir()
            invoke_environment["TMPDIR"] = str(raku_temp)
            with invoke_log_path.open("wb") as invoke_log:
                process = subprocess.Popen(
                    [str(binary), "invoke.txt"],
                    cwd=sandbox,
                    stdin=subprocess.DEVNULL,
                    stdout=invoke_log,
                    stderr=subprocess.STDOUT,
                    env=invoke_environment,
                )
                invoke_window = x11.find_window(args.timeout)
                x11.lib.XMapRaised(x11.display, invoke_window)
                x11.lib.XSetInputFocus(x11.display, invoke_window, 1, 0)
                x11.lib.XSync(x11.display, 0)
                wait_for_log(invoke_log_path, "filter: loaded user definitions", args.timeout)

                click(x11, invoke_window, 1, 60, 100)
                select_all(x11)
                execute(x11, invoke_window, "invoke-pipe", 60, 52, args.timeout, invoke_log_path, 1)
                wait_for_log(invoke_log_path, 'filter: echo "invoke-pipe"', args.timeout)
                wait_for_log(invoke_log_path, "job: selection replaced", args.timeout)
                execute(x11, invoke_window, "Putall", 10, 10, args.timeout, invoke_log_path, 1)
                wait_for_log(invoke_log_path, "file: saved invoke.txt", args.timeout)
                if invoke_source.read_bytes() != "filtered:invoke α β\n".encode("utf-8"):
                    raise HarnessFailure(f"replace-selection filter wrote unexpected bytes: {invoke_source.read_bytes()!r}")
                log_text = invoke_log_path.read_text(encoding="utf-8", errors="replace")
                echo_pos = log_text.find('filter: echo "invoke-pipe"')
                start_pos = log_text.find("filter: invoke-pipe started replace-selection")
                if echo_pos < 0 or start_pos < 0 or echo_pos > start_pos:
                    raise HarnessFailure("filter echo did not precede the job start")
                print("PASS: replace-selection filter pipes the body selection and echoes before run")

                execute(x11, invoke_window, "invoke-out", 60, 52, args.timeout, invoke_log_path, 1)
                wait_for_log(invoke_log_path, "filter: invoke-out started output-window", args.timeout)
                wait_for_log(invoke_log_path, "job: output opened", args.timeout)
                wait_for_log(invoke_log_path, "job: released id=", args.timeout)
                print("PASS: output-window filter opens a bounded job output window")

                before_opened = invoke_log_path.read_text(encoding="utf-8", errors="replace").count("job: output opened")
                execute(x11, invoke_window, "invoke-discard", 60, 52, args.timeout, invoke_log_path, 1)
                wait_for_log(invoke_log_path, "filter: invoke-discard started discard", args.timeout)
                wait_for_log(invoke_log_path, "job: released id=", args.timeout, 2)
                if not discard_marker.exists():
                    raise HarnessFailure("discard filter did not run its engine")
                after_opened = invoke_log_path.read_text(encoding="utf-8", errors="replace").count("job: output opened")
                if after_opened != before_opened:
                    raise HarnessFailure("discard filter opened an output window")
                print("PASS: discard filter runs its engine without an output window")

                if shutil.which("raku") is not None:
                    before_log = invoke_log_path.read_text(encoding="utf-8", errors="replace")
                    errors_opened_before = before_log.count("errors: opened")
                    errors_appended_before = before_log.count("errors: appended")
                    job_windows_before = before_log.count("job: output opened")
                    execute(x11, invoke_window, "raku-upper", 60, 52, args.timeout, invoke_log_path, 1)
                    wait_for_log(invoke_log_path, "filter: raku-upper started replace-selection", args.timeout)
                    wait_for_log(invoke_log_path, "job: selection replaced", args.timeout, 2)
                    execute(x11, invoke_window, "Putall", 10, 10, args.timeout, invoke_log_path, 2)
                    wait_for_log(invoke_log_path, "file: saved invoke.txt", args.timeout, 2)
                    expected_upper = "FILTERED:INVOKE Α Β\n".encode("utf-8")
                    if invoke_source.read_bytes() != expected_upper:
                        raise HarnessFailure(f"Raku -p filter wrote unexpected bytes: {invoke_source.read_bytes()!r}")
                    print("PASS: named Raku -p temp-file filter uppercases the selection")

                    execute(x11, invoke_window, "raku-lines", 60, 52, args.timeout, invoke_log_path, 1)
                    wait_for_log(invoke_log_path, "filter: raku-lines started output-window", args.timeout)
                    raku_n_marker = sandbox / "raku-n-ok"
                    deadline = time.monotonic() + args.timeout
                    while not raku_n_marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if raku_n_marker.read_bytes() != "FILTERED:INVOKE Α Β".encode("utf-8"):
                        raise HarnessFailure("Raku -n output filter did not receive the selected line")
                    print("PASS: named Raku -n filter receives selection stdin and routes output to a job window")

                    # A collapsed caret feeds the entire current buffer, including
                    # unsaved text, rather than an empty stream.
                    append_text(x11, invoke_window, 60, 100, "!")
                    one_liner = 'RakuEval say 2+2; spurt "raku-one-liner-ok", $*IN.slurp'
                    execute(x11, invoke_window, one_liner, 60, 52, args.timeout, invoke_log_path, 1)
                    wait_for_log(invoke_log_path, "raku: one-liner started", args.timeout)
                    one_liner_marker = sandbox / "raku-one-liner-ok"
                    deadline = time.monotonic() + args.timeout
                    while not one_liner_marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if one_liner_marker.read_bytes() != "FILTERED:INVOKE Α Β\n!".encode("utf-8"):
                        raise HarnessFailure("RakuEval did not receive the whole unsaved buffer")
                    log_text = invoke_log_path.read_text(encoding="utf-8", errors="replace")
                    echo_pos = log_text.find("raku: echo")
                    start_pos = log_text.find("raku: one-liner started")
                    if echo_pos < 0 or start_pos < 0 or echo_pos > start_pos:
                        raise HarnessFailure("RakuEval echo did not precede process start")
                    print("PASS: RakuEval reads the whole unsaved buffer at a collapsed caret")

                    # A non-empty highlight overrides whole-buffer input.
                    click(x11, invoke_window, 1, 60, 100)
                    x11.key(0xFFE3, True)
                    x11.tap(0xFF50)
                    x11.key(0xFFE3, False)
                    x11.key(0xFFE1, True)
                    for _ in range(8):
                        x11.tap(0xFF53)
                    x11.key(0xFFE1, False)
                    selected_liner = 'RakuEval spurt "raku-selected-ok", $*IN.slurp'
                    execute(x11, invoke_window, selected_liner, 60, 52, args.timeout, invoke_log_path, 2)
                    wait_for_log(invoke_log_path, "raku: one-liner started", args.timeout, 2)
                    selected_marker = sandbox / "raku-selected-ok"
                    deadline = time.monotonic() + args.timeout
                    while not selected_marker.exists() and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if selected_marker.read_bytes() != b"FILTERED":
                        raise HarnessFailure(f"RakuEval received unexpected selected stdin: {selected_marker.read_bytes()!r}")
                    print("PASS: RakuEval reads only a non-empty highlighted range")

                    deadline = time.monotonic() + args.timeout
                    while any(raku_temp.iterdir()) and time.monotonic() < deadline:
                        time.sleep(0.05)
                    if any(raku_temp.iterdir()):
                        raise HarnessFailure("completed Raku jobs left temporary programs behind")
                    after_log = invoke_log_path.read_text(encoding="utf-8", errors="replace")
                    if after_log.count("errors: opened") != errors_opened_before or after_log.count("errors: appended") != errors_appended_before:
                        raise HarnessFailure("Raku spawned or wrote to a redundant +Errors window")
                    if after_log.count("job: output opened") - job_windows_before != 4:
                        raise HarnessFailure("Raku did not create exactly one job window per invocation")
                    print("PASS: Raku spawns one job window only and no +Errors echo; temp files are reclaimed")
                    execute(x11, invoke_window, "Putall", 10, 10, args.timeout, invoke_log_path, 3)
                    wait_for_log(invoke_log_path, "file: saved invoke.txt", args.timeout, 3)

                x11.quit()
                wait_for_exit(process, args.timeout, invoke_log_path)
                process = None

            # M09.11: the explicit regex verb uses real Raku when available and
            # the native engine only when the executable is absent.
            native_regex_log = run_regex_case(args, binary, sandbox, x11, False)
            if "regex: native fallback" not in native_regex_log:
                raise HarnessFailure("Raku verb did not use native fallback without a PATH engine")
            print("PASS: Raku regex verb falls back to native search when Raku is absent")
            if shutil.which("raku") is not None:
                external_regex_log = run_regex_case(args, binary, sandbox, x11, True)
                echo_pos = external_regex_log.find('regex: echo "/needle/"')
                start_pos = external_regex_log.find("regex: external search started")
                if echo_pos < 0 or start_pos < 0 or echo_pos > start_pos:
                    raise HarnessFailure("external regex echo did not precede the job start")
                print("PASS: real Raku regex searches forward, wraps, and returns UTF-8 byte selections")
            else:
                print("SKIP: real Raku regex execution (raku is not installed)")

            # M09.13: external commands run in the shell — synchronously by
            # default (output to +Errors), `Async <cmd>` for the job service.
            route_content = "route α β\n".encode("utf-8")

            plain_result, plain_log = run_external_case(args, binary, sandbox, x11, job_helper, f"{job_helper.name} echo", f"{job_helper.name} echo", "plain", route_content, False)
            if plain_result != route_content:
                raise HarnessFailure(f"plain command modified the source file: {plain_result!r}")
            print("PASS: plain command runs synchronously in the shell and writes output to +Errors")

            pipe_result, pipe_log = run_external_case(args, binary, sandbox, x11, job_helper, f"|{job_helper.name} pipe", f"{job_helper.name} pipe", "pipe", route_content, True)
            if pipe_result != "filtered:route α β\n".encode("utf-8"):
                raise HarnessFailure(f"| command wrote unexpected bytes: {pipe_result!r}")
            print("PASS: | pipes the body selection through the shell and replaces it")

            replace_result, _ = run_external_case(args, binary, sandbox, x11, job_helper, f"<{job_helper.name} echo", f"{job_helper.name} echo", "replace", route_content, True)
            if replace_result != b"stdout=\n":
                raise HarnessFailure(f"< command wrote unexpected bytes: {replace_result!r}")
            print("PASS: < replaces the selection with command output over empty stdin")

            feed_result, feed_log = run_external_case(args, binary, sandbox, x11, job_helper, f">{job_helper.name} echo", f"{job_helper.name} echo", "feed", route_content, False)
            if feed_result != route_content:
                raise HarnessFailure(f"> command modified the source file: {feed_result!r}")
            print("PASS: > feeds the selection to +Errors without replacing it")

            for log_text in (plain_log, pipe_log, feed_log):
                if "pipe: echo" in log_text:
                    raise HarnessFailure("external command echoed its command text")
            print("PASS: external commands do not echo their command text")

            async_result = run_async_case(args, binary, sandbox, x11, job_helper, f"Async |{job_helper.name} pipe", f"{job_helper.name} pipe")
            if async_result != "filtered:async α β\n".encode("utf-8"):
                raise HarnessFailure(f"Async pipe wrote unexpected bytes: {async_result!r}")
            print("PASS: Async runs the command through the job service")

            # M09.13: Jobs lists running async commands; Kill stops one by id.
            jobs_source = sandbox / "jobs.txt"
            jobs_source.write_bytes(b"jobs\n")
            jobs_log_path = sandbox / "jobs-hammer.log"
            jobs_env = os.environ.copy()
            jobs_env["HAMMER_LOG"] = ""
            jobs_env["PATH"] = f"{job_helper.parent}{os.pathsep}{jobs_env.get('PATH', '')}"
            jobs_env["XDG_STATE_HOME"] = str(sandbox / "jobs-state")
            with jobs_log_path.open("wb") as jobs_log:
                process = subprocess.Popen(
                    [str(binary), "jobs.txt"],
                    cwd=sandbox,
                    stdin=subprocess.DEVNULL,
                    stdout=jobs_log,
                    stderr=subprocess.STDOUT,
                    env=jobs_env,
                )
                jobs_window = x11.find_window(args.timeout)
                x11.lib.XMapRaised(x11.display, jobs_window)
                x11.lib.XSetInputFocus(x11.display, jobs_window, 1, 0)
                x11.lib.XSync(x11.display, 0)
                time.sleep(0.3)
                execute_pipe(x11, jobs_window, f"Async {job_helper.name} ignore")
                wait_for_log(jobs_log_path, "shell: started async command id=", args.timeout)
                job_match = re.search(r"shell: started async command id=(\d+)", jobs_log_path.read_text(encoding="utf-8", errors="replace"))
                if job_match is None:
                    raise HarnessFailure("could not determine the async job id")
                job_id = job_match.group(1)

                execute(x11, jobs_window, "Jobs", 10, 10, args.timeout, jobs_log_path, 1)
                wait_for_log(jobs_log_path, "job: listed 1 running job(s) in window", args.timeout)
                execute(x11, jobs_window, f"Kill {job_id}", 10, 10, args.timeout, jobs_log_path, 1)
                wait_for_log(jobs_log_path, f"job: Kill requested for id={job_id}", args.timeout)
                wait_for_log(jobs_log_path, f"job: released id={job_id}", args.timeout)
                execute(x11, jobs_window, "Jobs", 10, 10, args.timeout, jobs_log_path, 2)
                wait_for_log(jobs_log_path, "job: listed 0 running job(s)", args.timeout)
                print("PASS: Jobs lists running async commands and Kill stops one by id")
                x11.quit()
                wait_for_exit(process, args.timeout, jobs_log_path)
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
