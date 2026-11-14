#!/usr/bin/env python3
"""External exact-operation SIGKILL harness for Hammer recovery journals."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import random
import selectors
import shutil
import signal
import subprocess
import sys
import tempfile
import time


class HarnessFailure(RuntimeError):
    pass


def read_event(process: subprocess.Popen[bytes], timeout: float) -> tuple[str, int]:
    deadline = time.monotonic() + timeout
    assert process.stdout is not None
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HarnessFailure(f"child {process.pid} timed out waiting for an operation point")
            if not selector.select(remaining):
                continue
            line = process.stdout.readline()
            if not line:
                code = process.poll()
                raise HarnessFailure(f"child {process.pid} closed its protocol stream (exit {code})")
            text = line.decode("utf-8", errors="strict").strip()
            if text == "DONE":
                return "done", 0
            fields = text.split(" ", 2)
            if len(fields) == 3 and fields[0] == "POINT" and fields[1].isdigit():
                return "point", int(fields[1])
            raise HarnessFailure(f"invalid child protocol line: {text!r}")
    finally:
        selector.close()


def child_stderr(process: subprocess.Popen[bytes]) -> str:
    if process.stderr is None:
        return ""
    return process.stderr.read().decode("utf-8", errors="replace").strip()


def run_writer(binary: Path, directory: Path, kill_point: int | None, timeout: float) -> int:
    process = subprocess.Popen(
        [str(binary), "write", str(directory)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    last_point = 0
    try:
        while True:
            event, point = read_event(process, timeout)
            if event == "done":
                code = process.wait(timeout=timeout)
                if code != 0:
                    raise HarnessFailure(f"writer exited {code}: {child_stderr(process)}")
                return last_point
            last_point = point
            if point == kill_point:
                process.kill()
                code = process.wait(timeout=timeout)
                if code != -signal.SIGKILL:
                    raise HarnessFailure(f"kill-point child exited {code}, expected SIGKILL")
                return point
            assert process.stdin is not None
            process.stdin.write(b"\n")
            process.stdin.flush()
    except HarnessFailure as failure:
        if process.poll() is None:
            process.kill()
            process.wait(timeout=timeout)
        detail = child_stderr(process)
        if detail:
            raise HarnessFailure(f"{failure}; child stderr: {detail}") from failure
        raise
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        for stream in (process.stdin, process.stdout, process.stderr):
            if stream is not None:
                stream.close()


def run_verifier(binary: Path, directory: Path, timeout: float) -> str:
    try:
        result = subprocess.run(
            [str(binary), "verify", str(directory)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise HarnessFailure(f"verifier timed out for {directory}") from error
    stdout = result.stdout.decode("utf-8", errors="strict").strip()
    stderr = result.stderr.decode("utf-8", errors="replace").strip()
    if result.returncode != 0:
        raise HarnessFailure(f"verifier exited {result.returncode}: {stderr or stdout}")
    if stdout != "NO_RECOVERY" and not stdout.startswith("RECOVERED "):
        raise HarnessFailure(f"invalid verifier output: {stdout!r}")
    return stdout


def isolated_case(binary: Path, kill_point: int | None, timeout: float) -> str:
    directory = Path(tempfile.mkdtemp(prefix="hammer-m04-08-recovery-"))
    succeeded = False
    try:
        run_writer(binary, directory, kill_point, timeout)
        result = run_verifier(binary, directory, timeout)
        succeeded = True
        return result
    except HarnessFailure as failure:
        label = "normal completion" if kill_point is None else f"kill point {kill_point}"
        raise HarnessFailure(f"{label} failed in preserved sandbox {directory}: {failure}") from failure
    finally:
        if succeeded:
            shutil.rmtree(directory)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--seed", type=lambda value: int(value, 0), default=0x0408)
    parser.add_argument("--random-runs", type=int, default=12)
    parser.add_argument("--timeout", type=float, default=5.0)
    args = parser.parse_args()
    if os.name != "posix":
        parser.error("the SIGKILL integration harness requires POSIX")
    if not 0 <= args.random_runs <= 1000:
        parser.error("--random-runs must be between 0 and 1000")
    if not 0.1 <= args.timeout <= 30.0:
        parser.error("--timeout must be between 0.1 and 30 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"helper binary does not exist: {binary}")

    try:
        completed = isolated_case(binary, None, args.timeout)
        if not completed.startswith("RECOVERED 2 2 "):
            raise HarnessFailure(f"normal completion did not recover the final generation: {completed}")
        # A separate calibration run determines the exact finite operation count.
        calibration_dir = Path(tempfile.mkdtemp(prefix="hammer-m04-08-calibration-"))
        try:
            last_point = run_writer(binary, calibration_dir, None, args.timeout)
            calibration_result = run_verifier(binary, calibration_dir, args.timeout)
        except HarnessFailure as failure:
            raise HarnessFailure(f"calibration failed in preserved sandbox {calibration_dir}: {failure}") from failure
        else:
            shutil.rmtree(calibration_dir)
        if not 1 <= last_point <= 10000:
            raise HarnessFailure(f"invalid operation-point count {last_point}")
        if not calibration_result.startswith("RECOVERED 2 2 "):
            raise HarnessFailure("calibration did not recover the final generation")

        rng = random.Random(args.seed)
        points = list(range(1, last_point + 1))
        rng.shuffle(points)
        random_points = [rng.randint(1, last_point) for _ in range(args.random_runs)]
        recovered = 0
        no_recovery = 0
        torn = 0
        generations = {0: 0, 1: 0, 2: 0}
        for point in points + random_points:
            result = isolated_case(binary, point, args.timeout)
            if result == "NO_RECOVERY":
                no_recovery += 1
                continue
            recovered += 1
            fields = result.split(" ")
            generations[int(fields[1])] += 1
            if fields[3] == "Torn_Record":
                torn += 1
        if any(count == 0 for count in generations.values()):
            raise HarnessFailure(f"kill coverage missed a recovery generation: {generations}")
        if torn == 0:
            raise HarnessFailure("kill coverage did not exercise a torn journal tail")
        print(
            f"PASS: {last_point} exact kill points + {len(random_points)} seeded random repetitions; "
            f"{recovered} recovered, {no_recovery} before initial journal validity, "
            f"{torn} torn tails, generations={generations}; seed={args.seed}"
        )
        return 0
    except (HarnessFailure, OSError, UnicodeError) as error:
        print(f"FAIL: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
