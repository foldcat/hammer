#!/usr/bin/env python3
"""Separate-process Windows clipboard interoperability checks for Hammer."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import selectors
import shutil
import subprocess
import sys
import tempfile
import time


class HarnessFailure(RuntimeError):
    pass


def run_checked(command: list[str], env: dict[str, str], timeout: float) -> None:
    try:
        result = subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            env=env,
            timeout=timeout,
            check=False,
        )
    except subprocess.TimeoutExpired as error:
        raise HarnessFailure(f"command timed out: {command}") from error
    if result.returncode != 0:
        stdout = result.stdout.decode("utf-8", errors="replace").strip()
        stderr = result.stderr.decode("utf-8", errors="replace").strip()
        raise HarnessFailure(f"command exited {result.returncode}: {command}: {stderr or stdout}")


def wait_ready(process: subprocess.Popen[bytes], timeout: float) -> None:
    assert process.stdout is not None
    deadline = time.monotonic() + timeout
    selector = selectors.DefaultSelector()
    selector.register(process.stdout, selectors.EVENT_READ)
    try:
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise HarnessFailure(f"writer {process.pid} timed out waiting for clipboard ownership")
            if not selector.select(remaining):
                continue
            line = process.stdout.readline()
            if not line:
                raise HarnessFailure(f"writer {process.pid} exited {process.poll()} before clipboard ownership")
            if line.strip() == b"ready clipboard owner":
                return
    finally:
        selector.close()


def release_owner(process: subprocess.Popen[bytes], timeout: float) -> None:
    if process.stdin is not None:
        process.stdin.close()
    if process.poll() is None:
        try:
            process.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait(timeout=timeout)
    if process.stdout is not None:
        process.stdout.close()
    if process.stderr is not None:
        process.stderr.close()


def transfer(wine: str, binary: Path, writer: str, reader: str, payload: Path, output: Path, env: dict[str, str], timeout: float) -> None:
    process = subprocess.Popen(
        [wine, str(binary), writer + "-serve", str(payload)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        env=env,
    )
    try:
        wait_ready(process, timeout)
        run_checked([wine, str(binary), reader, str(output)], env, timeout)
    finally:
        release_owner(process, timeout)


def assert_payload(output: Path, expected: bytes, label: str) -> None:
    actual = output.read_bytes()
    if actual != expected:
        raise HarnessFailure(f"{label}: payload mismatch ({len(actual)} bytes, expected {len(expected)})")
    print(f"PASS: {label} ({len(expected)} bytes)")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=45.0)
    args = parser.parse_args()
    if not 5.0 <= args.timeout <= 120.0:
        parser.error("--timeout must be between 5 and 120 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error(f"test binary does not exist: {binary}")
    wine = shutil.which("wine")
    wineserver = shutil.which("wineserver")
    if wine is None or wineserver is None:
        parser.error("wine and wineserver are required")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m06-08-windows-clipboard-"))
    env = os.environ.copy()
    env.update({
        "WINEDEBUG": "-all",
        "WINEARCH": "win64",
        "WINEPREFIX": str(sandbox / "wine-prefix"),
    })
    succeeded = False
    try:
        unicode_payload = "ASCII é Ελληνικά кириллица 漢字 A\u0301 😀 עברית\n".encode("utf-8")
        unicode_file = sandbox / "unicode.txt"
        unicode_file.write_bytes(unicode_payload)
        large_payload = unicode_payload * (256 * 1024 // len(unicode_payload) + 1)
        large_file = sandbox / "large.txt"
        large_file.write_bytes(large_payload)

        transfer(wine, binary, "write", "peer-read", unicode_file, sandbox / "unicode-product-peer.txt", env, args.timeout)
        assert_payload(sandbox / "unicode-product-peer.txt", unicode_payload, "Hammer writer -> external Win32 reader")
        transfer(wine, binary, "peer-write", "read", unicode_file, sandbox / "unicode-peer-product.txt", env, args.timeout)
        assert_payload(sandbox / "unicode-peer-product.txt", unicode_payload, "external Win32 writer -> Hammer reader")
        transfer(wine, binary, "write", "peer-read", large_file, sandbox / "large-product-peer.txt", env, args.timeout)
        assert_payload(sandbox / "large-product-peer.txt", large_payload, "Hammer writer -> external Win32 reader, large Unicode")
        transfer(wine, binary, "peer-write", "read", large_file, sandbox / "large-peer-product.txt", env, args.timeout)
        assert_payload(sandbox / "large-peer-product.txt", large_payload, "external Win32 writer -> Hammer reader, large Unicode")
        succeeded = True
        print("PASS: all Windows clipboard interoperability checks")
        return 0
    except (HarnessFailure, OSError) as error:
        print(f"FAIL: {error}; preserved sandbox: {sandbox}", file=sys.stderr)
        return 1
    finally:
        try:
            subprocess.run(
                [wineserver, "-k"],
                stdin=subprocess.DEVNULL,
                stdout=subprocess.DEVNULL,
                stderr=subprocess.DEVNULL,
                env=env,
                timeout=10,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            print(f"cleanup warning: could not stop the isolated wineserver: {error}", file=sys.stderr)
        if succeeded:
            shutil.rmtree(sandbox)


if __name__ == "__main__":
    raise SystemExit(main())
