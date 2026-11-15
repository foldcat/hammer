#!/usr/bin/env python3
"""Real X11 typing, rendering, undo, and dirty-close smoke test."""

from __future__ import annotations

import argparse
import ctypes
import ctypes.util
import hashlib
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time


class HarnessFailure(RuntimeError):
    pass


class X11:
    def __init__(self) -> None:
        x11_name = ctypes.util.find_library("X11")
        xtst_name = ctypes.util.find_library("Xtst")
        if x11_name is None or xtst_name is None:
            raise HarnessFailure("libX11 and libXtst are required")
        self.lib = ctypes.CDLL(x11_name)
        self.xtst = ctypes.CDLL(xtst_name)
        self.lib.XOpenDisplay.argtypes = [ctypes.c_char_p]
        self.lib.XOpenDisplay.restype = ctypes.c_void_p
        display = self.lib.XOpenDisplay(None)
        if not display:
            raise HarnessFailure("cannot open DISPLAY")
        self.display = display
        self._declare()

    def _declare(self) -> None:
        lib = self.lib
        lib.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
        lib.XDefaultRootWindow.restype = ctypes.c_ulong
        lib.XQueryTree.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.c_ulong),
            ctypes.POINTER(ctypes.POINTER(ctypes.c_ulong)),
            ctypes.POINTER(ctypes.c_uint),
        ]
        lib.XFetchName.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.POINTER(ctypes.c_char_p)]
        lib.XFree.argtypes = [ctypes.c_void_p]
        lib.XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        lib.XMapRaised.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        lib.XSync.argtypes = [ctypes.c_void_p, ctypes.c_int]
        lib.XKeysymToKeycode.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
        lib.XKeysymToKeycode.restype = ctypes.c_ubyte
        lib.XGetImage.argtypes = [
            ctypes.c_void_p,
            ctypes.c_ulong,
            ctypes.c_int,
            ctypes.c_int,
            ctypes.c_uint,
            ctypes.c_uint,
            ctypes.c_ulong,
            ctypes.c_int,
        ]
        lib.XGetImage.restype = ctypes.c_void_p
        lib.XGetPixel.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.c_int]
        lib.XGetPixel.restype = ctypes.c_ulong
        lib.XDestroyImage.argtypes = [ctypes.c_void_p]
        lib.XCloseDisplay.argtypes = [ctypes.c_void_p]
        self.xtst.XTestFakeKeyEvent.argtypes = [ctypes.c_void_p, ctypes.c_uint, ctypes.c_int, ctypes.c_ulong]
        self.xtst.XTestFakeKeyEvent.restype = ctypes.c_int

    def close(self) -> None:
        self.lib.XCloseDisplay(self.display)

    def find_window(self, timeout: float) -> int:
        deadline = time.monotonic() + timeout
        root = self.lib.XDefaultRootWindow(self.display)
        while time.monotonic() < deadline:
            root_return = ctypes.c_ulong()
            parent_return = ctypes.c_ulong()
            children = ctypes.POINTER(ctypes.c_ulong)()
            count = ctypes.c_uint()
            status = self.lib.XQueryTree(
                self.display,
                root,
                ctypes.byref(root_return),
                ctypes.byref(parent_return),
                ctypes.byref(children),
                ctypes.byref(count),
            )
            if status:
                for index in range(count.value):
                    window = children[index]
                    name = ctypes.c_char_p()
                    if self.lib.XFetchName(self.display, window, ctypes.byref(name)) and name.value:
                        title = name.value.decode("utf-8", errors="replace")
                        self.lib.XFree(name)
                        if title == "Hammer":
                            self.lib.XFree(children)
                            return int(window)
                if children:
                    self.lib.XFree(children)
            time.sleep(0.05)
        raise HarnessFailure("timed out waiting for the Hammer window")

    def key(self, keysym: int, down: bool) -> None:
        keycode = self.lib.XKeysymToKeycode(self.display, keysym)
        if keycode == 0:
            raise HarnessFailure(f"keysym 0x{keysym:x} has no keycode")
        if not self.xtst.XTestFakeKeyEvent(self.display, keycode, int(down), 0):
            raise HarnessFailure("XTestFakeKeyEvent failed")

    def tap(self, keysym: int) -> None:
        self.key(keysym, True)
        self.key(keysym, False)
        self.lib.XSync(self.display, 0)

    def pixels(self, window: int) -> bytes:
        image = self.lib.XGetImage(self.display, window, 0, 0, 800, 600, 0xFFFFFFFFFFFFFFFF, 2)
        if not image:
            raise HarnessFailure("XGetImage failed")
        try:
            digest = hashlib.sha256()
            for y in range(24, 80):
                for x in range(10, 220):
                    pixel = self.lib.XGetPixel(image, x, y)
                    digest.update(int(pixel).to_bytes(8, sys.byteorder))
            return digest.digest()
        finally:
            self.lib.XDestroyImage(image)


def wait_for_exit(process: subprocess.Popen[bytes], timeout: float, log_path: Path) -> None:
    try:
        result = process.wait(timeout=timeout)
    except subprocess.TimeoutExpired as error:
        raise HarnessFailure("Hammer did not exit after a clean Escape") from error
    if result != 0:
        raise HarnessFailure(f"Hammer exited {result}; log: {log_path}")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--timeout", type=float, default=15.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name the Hammer executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-m06-09-typing-"))
    process: subprocess.Popen[bytes] | None = None
    x11: X11 | None = None
    succeeded = False
    log_path = sandbox / "hammer.log"
    try:
        x11 = X11()
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["XDG_STATE_HOME"] = str(sandbox / "state")
        with log_path.open("wb") as log:
            process = subprocess.Popen(
                [str(binary)],
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
            initial = x11.pixels(window)

            for keysym in (ord("a"), ord("b"), ord("c"), 0xFF0D, ord("d")):
                x11.tap(keysym)
            time.sleep(0.3)
            typed = x11.pixels(window)
            if typed == initial:
                raise HarnessFailure(f"typing did not change body text pixels; log: {log_path}")
            print("PASS: typed text and newline rendered in the product window")

            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            undone = x11.pixels(window)
            if undone != initial:
                raise HarnessFailure(f"Ctrl+Z did not restore the initial pixels; log: {log_path}")
            print("PASS: one Ctrl+Z undid the complete typing run")

            x11.key(0xFFE3, True)
            x11.key(0xFFE1, True)
            x11.tap(ord("z"))
            x11.key(0xFFE1, False)
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            if x11.pixels(window) != typed:
                raise HarnessFailure(f"Ctrl+Shift+Z did not restore the typed pixels; log: {log_path}")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            time.sleep(0.3)
            if x11.pixels(window) != initial:
                raise HarnessFailure("the second undo did not restore the initial pixels")
            print("PASS: redo and repeated undo round-trip through the product")

            for keysym in (ord("a"), 0xFF09, ord("b")):
                x11.tap(keysym)
            time.sleep(0.3)
            tabbed = x11.pixels(window)
            for _ in range(3):
                x11.key(0xFFE3, True)
                x11.tap(ord("z"))
                x11.key(0xFFE3, False)
                time.sleep(0.2)
            if x11.pixels(window) != initial:
                raise HarnessFailure("undoing the Tab editing sequence did not restore the initial pixels")
            for keysym in (ord("a"), 0x20, 0x20, 0x20, ord("b")):
                x11.tap(keysym)
            time.sleep(0.3)
            spaced = x11.pixels(window)
            if tabbed == initial:
                raise HarnessFailure("Tab produced no visible text change")
            if spaced != tabbed:
                raise HarnessFailure(f"Tab pixels {tabbed.hex()} differ from three spaces {spaced.hex()}")
            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            time.sleep(0.2)
            print("PASS: Tab renders as whitespace to the next four-column tab stop")

            x11.tap(ord("x"))
            x11.tap(0xFF08)
            time.sleep(0.3)
            if x11.pixels(window) != initial:
                raise HarnessFailure("Backspace did not remove the typed grapheme")
            print("PASS: Backspace consumes a real product key event")
            for _ in range(2):
                x11.key(0xFFE3, True)
                x11.tap(ord("z"))
                x11.key(0xFFE3, False)
                time.sleep(0.2)

            x11.tap(ord("x"))
            time.sleep(0.2)
            x11.tap(0xFF1B)
            time.sleep(0.3)
            if process.poll() is not None:
                raise HarnessFailure("dirty buffer quit was not blocked")
            print("PASS: Escape preserved unsaved text and kept the editor open")

            x11.key(0xFFE3, True)
            x11.tap(ord("z"))
            x11.key(0xFFE3, False)
            time.sleep(0.2)
            x11.tap(0xFF1B)
            wait_for_exit(process, args.timeout, log_path)
            process = None
        succeeded = True
        print("PASS: all X11 product typing checks")
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
