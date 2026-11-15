#!/usr/bin/env python3
"""Separate-process X11 clipboard interoperability checks for Hammer."""

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


class Child:
    def __init__(self, command: list[str], sandbox: Path, name: str, timeout: float):
        self.timeout = timeout
        self.log_path = sandbox / f"{name}.log"
        self.log = self.log_path.open("wb")
        try:
            self.process = subprocess.Popen(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=self.log,
            )
        except OSError:
            self.log.close()
            raise

    def wait_ready(self, prefix: str) -> None:
        assert self.process.stdout is not None
        deadline = time.monotonic() + self.timeout
        selector = selectors.DefaultSelector()
        selector.register(self.process.stdout, selectors.EVENT_READ)
        try:
            while True:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    raise HarnessFailure(f"child {self.process.pid} timed out waiting for {prefix!r}")
                if not selector.select(remaining):
                    continue
                line = self.process.stdout.readline()
                if not line:
                    raise HarnessFailure(
                        f"child {self.process.pid} exited {self.process.poll()} before readiness; "
                        f"log: {self.log_path}"
                    )
                if line.decode("utf-8", errors="strict").startswith(prefix):
                    return
        finally:
            selector.close()

    def stop(self) -> None:
        if self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=self.timeout)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=self.timeout)
        if self.process.stdout is not None:
            self.process.stdout.close()
        self.log.close()


children: list[Child] = []


def start_child(command: list[str], sandbox: Path, name: str, timeout: float, ready: str) -> Child:
    child = Child(command, sandbox, name, timeout)
    children.append(child)
    child.wait_ready(ready)
    return child


def stop_child(child: Child) -> None:
    child.stop()
    children.remove(child)


def run_checked(command: list[str], timeout: float, output: Path | None = None) -> None:
    try:
        if output is None:
            result = subprocess.run(
                command,
                stdin=subprocess.DEVNULL,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=timeout,
                check=False,
            )
            stdout = result.stdout
        else:
            with output.open("wb") as stream:
                result = subprocess.run(
                    command,
                    stdin=subprocess.DEVNULL,
                    stdout=stream,
                    stderr=subprocess.PIPE,
                    timeout=timeout,
                    check=False,
                )
            stdout = b""
    except subprocess.TimeoutExpired as error:
        raise HarnessFailure(f"command timed out: {command}") from error
    if result.returncode != 0:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise HarnessFailure(f"command exited {result.returncode}: {command}: {detail or stdout!r}")


def assert_payload(output: Path, expected: bytes, label: str) -> None:
    actual = output.read_bytes()
    if actual != expected:
        raise HarnessFailure(f"{label}: payload mismatch ({len(actual)} bytes, expected {len(expected)})")
    print(f"PASS: {label} ({len(expected)} bytes)")


def product_read(driver: Path, selection: str, output: Path, timeout: float) -> None:
    run_checked([str(driver), "read", selection, str(output)], timeout)


def product_serve(driver: Path, selection: str, payload: Path, sandbox: Path, name: str, timeout: float) -> Child:
    return start_child(
        [str(driver), "serve", selection, str(payload)], sandbox, name, timeout, f"ready {selection} "
    )


def peer_serve(peer: Path, selection: str, payload: Path, sandbox: Path, name: str, timeout: float) -> Child:
    return start_child(
        [str(peer), "serve", selection, str(payload)], sandbox, name, timeout, f"ready {selection} "
    )


def external_to_product(driver: Path, peer: Path, selection: str, payload: Path, expected: bytes, sandbox: Path, timeout: float) -> None:
    owner = peer_serve(peer, selection, payload, sandbox, "external-owner", timeout)
    try:
        output = sandbox / "product-read.txt"
        product_read(driver, selection, output, timeout)
        assert_payload(output, expected, f"external {selection} owner -> Hammer reader")
    finally:
        stop_child(owner)


def product_to_external(driver: Path, peer: Path, xclip: str, selection: str, payload: Path, expected: bytes, sandbox: Path, timeout: float) -> None:
    owner = product_serve(driver, selection, payload, sandbox, "product-owner", timeout)
    try:
        output = sandbox / "external-read.txt"
        run_checked([str(peer), "get", selection, "-o", str(output), "--timeout-ms", "5000"], timeout)
        assert_payload(output, expected, f"Hammer {selection} owner -> external reader")
        xclip_output = sandbox / "xclip-read.txt"
        run_checked([xclip, "-selection", selection.lower(), "-target", "UTF8_STRING", "-out"], timeout, xclip_output)
        assert_payload(xclip_output, expected, f"Hammer {selection} owner -> xclip reader")
    finally:
        stop_child(owner)


def manager_persistence(driver: Path, peer: Path, payload: Path, expected: bytes, sandbox: Path, timeout: float) -> None:
    manager = start_child(
        [str(peer), "manage", str(sandbox / "manager-data.txt")],
        sandbox,
        "clipboard-manager",
        timeout,
        "ready CLIPBOARD_MANAGER",
    )
    try:
        run_checked([str(driver), "write-exit", "CLIPBOARD", str(payload)], timeout)
        output = sandbox / "persisted-read.txt"
        run_checked([str(peer), "get", "CLIPBOARD", "-o", str(output), "--timeout-ms", "5000"], timeout)
        assert_payload(output, expected, "SAVE_TARGETS handoff persists after Hammer exits")
    finally:
        stop_child(manager)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--driver", required=True, type=Path)
    parser.add_argument("--peer", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    driver = args.driver.resolve()
    peer = args.peer.resolve()
    if not driver.is_file() or not peer.is_file():
        parser.error("both helper binaries must exist")
    xclip = shutil.which("xclip")
    if xclip is None:
        parser.error("xclip is required for the external-application checks")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m06-08-clipboard-"))
    succeeded = False
    try:
        unicode_payload = "ASCII é Ελληνικά кириллица 漢字 A\u0301 😀 עברית\n".encode("utf-8")
        unicode_file = sandbox / "unicode.txt"
        unicode_file.write_bytes(unicode_payload)
        large_payload = unicode_payload * (256 * 1024 // len(unicode_payload) + 1)
        large_file = sandbox / "large.txt"
        large_file.write_bytes(large_payload)

        external_to_product(driver, peer, "CLIPBOARD", unicode_file, unicode_payload, sandbox, args.timeout)
        product_to_external(driver, peer, xclip, "CLIPBOARD", unicode_file, unicode_payload, sandbox, args.timeout)
        external_to_product(driver, peer, "CLIPBOARD", large_file, large_payload, sandbox, args.timeout)
        product_to_external(driver, peer, xclip, "CLIPBOARD", large_file, large_payload, sandbox, args.timeout)
        external_to_product(driver, peer, "PRIMARY", unicode_file, unicode_payload, sandbox, args.timeout)
        product_to_external(driver, peer, xclip, "PRIMARY", unicode_file, unicode_payload, sandbox, args.timeout)
        manager_persistence(driver, peer, unicode_file, unicode_payload, sandbox, args.timeout)
        succeeded = True
        print("PASS: all X11 clipboard interoperability checks")
        return 0
    except (HarnessFailure, OSError, UnicodeError) as error:
        print(f"FAIL: {error}; preserved sandbox: {sandbox}", file=sys.stderr)
        return 1
    finally:
        for child in reversed(children[:]):
            try:
                stop_child(child)
            except (OSError, subprocess.TimeoutExpired) as error:
                print(f"cleanup warning: {error}", file=sys.stderr)
        if succeeded:
            shutil.rmtree(sandbox)


if __name__ == "__main__":
    raise SystemExit(main())
