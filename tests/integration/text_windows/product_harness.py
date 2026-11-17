#!/usr/bin/env python3
"""Native Windows DirectWrite product rendering smoke test."""

from __future__ import annotations

import argparse
import ctypes
from ctypes import wintypes
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import time
import zlib

LINES = [
    "ASCII A e\u0301fi and box \u250c\u2500\u2510",
    "Hebrew: \u05d0\u05d1\u05d2 123",
    "Arabic: \u0645\u0631\u062d\u0628\u0627",
    "Devanagari: \u0928\u092e\u0938\u094d\u0924\u0947",
    "Math: \u2200\u2211\u222b\u221a\u221e\u2260\u2264\u2265  Currency: \u20ac\u00a3\u00a5\u20b9",
    "Emoji: \U0001f600 \U0001f469\u200d\U0001f4bb",
]

user32 = ctypes.WinDLL("user32", use_last_error=True)
gdi32 = ctypes.WinDLL("gdi32", use_last_error=True)

ENUM_WINDOWS_PROC = ctypes.WINFUNCTYPE(wintypes.BOOL, wintypes.HWND, wintypes.LPARAM)
user32.EnumWindows.argtypes = [ENUM_WINDOWS_PROC, wintypes.LPARAM]
user32.EnumWindows.restype = wintypes.BOOL
user32.GetWindowThreadProcessId.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.DWORD)]
user32.GetWindowThreadProcessId.restype = wintypes.DWORD
user32.IsWindowVisible.argtypes = [wintypes.HWND]
user32.IsWindowVisible.restype = wintypes.BOOL
user32.GetClientRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetClientRect.restype = wintypes.BOOL
user32.GetWindowRect.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.RECT)]
user32.GetWindowRect.restype = wintypes.BOOL
user32.ClientToScreen.argtypes = [wintypes.HWND, ctypes.POINTER(wintypes.POINT)]
user32.ClientToScreen.restype = wintypes.BOOL
user32.GetDC.argtypes = [wintypes.HWND]
user32.GetDC.restype = wintypes.HDC
user32.ReleaseDC.argtypes = [wintypes.HWND, wintypes.HDC]
user32.ReleaseDC.restype = ctypes.c_int
user32.SetWindowPos.argtypes = [wintypes.HWND, wintypes.HWND, ctypes.c_int, ctypes.c_int, ctypes.c_int, ctypes.c_int, wintypes.UINT]
user32.SetWindowPos.restype = wintypes.BOOL
user32.PrintWindow.argtypes = [wintypes.HWND, wintypes.HDC, wintypes.UINT]
user32.PrintWindow.restype = wintypes.BOOL

gdi32.CreateCompatibleDC.argtypes = [wintypes.HDC]
gdi32.CreateCompatibleDC.restype = wintypes.HDC
gdi32.CreateCompatibleBitmap.argtypes = [wintypes.HDC, ctypes.c_int, ctypes.c_int]
gdi32.CreateCompatibleBitmap.restype = wintypes.HBITMAP
gdi32.SelectObject.argtypes = [wintypes.HDC, wintypes.HGDIOBJ]
gdi32.SelectObject.restype = wintypes.HGDIOBJ
gdi32.DeleteObject.argtypes = [wintypes.HGDIOBJ]
gdi32.DeleteObject.restype = wintypes.BOOL
gdi32.DeleteDC.argtypes = [wintypes.HDC]
gdi32.DeleteDC.restype = wintypes.BOOL
gdi32.GetDIBits.argtypes = [wintypes.HDC, wintypes.HBITMAP, wintypes.UINT, wintypes.UINT, ctypes.c_void_p, ctypes.c_void_p, wintypes.UINT]
gdi32.GetDIBits.restype = ctypes.c_int

DIB_RGB_COLORS = 0
BI_RGB = 0


class BITMAPINFOHEADER(ctypes.Structure):
    _fields_ = [
        ("biSize", wintypes.DWORD),
        ("biWidth", wintypes.LONG),
        ("biHeight", wintypes.LONG),
        ("biPlanes", wintypes.WORD),
        ("biBitCount", wintypes.WORD),
        ("biCompression", wintypes.DWORD),
        ("biSizeImage", wintypes.DWORD),
        ("biXPelsPerMeter", wintypes.LONG),
        ("biYPelsPerMeter", wintypes.LONG),
        ("biClrUsed", wintypes.DWORD),
        ("biClrImportant", wintypes.DWORD),
    ]


class BITMAPINFO(ctypes.Structure):
    _fields_ = [("bmiHeader", BITMAPINFOHEADER), ("bmiColors", wintypes.DWORD * 3)]


def find_window(pid: int, timeout: float) -> wintypes.HWND:
    deadline = time.monotonic() + timeout
    found: list[wintypes.HWND] = []

    def callback(hwnd: wintypes.HWND, _: wintypes.LPARAM) -> bool:
        window_pid = wintypes.DWORD()
        user32.GetWindowThreadProcessId(hwnd, ctypes.byref(window_pid))
        if window_pid.value == pid and user32.IsWindowVisible(hwnd):
            found.append(hwnd)
            return False
        return True

    while time.monotonic() < deadline:
        found.clear()
        user32.EnumWindows(ENUM_WINDOWS_PROC(callback), 0)
        if found:
            return found[0]
        if time.monotonic() >= deadline:
            break
        time.sleep(0.05)
    raise RuntimeError(f"test process {pid} did not create a visible window")


def capture_window(hwnd: wintypes.HWND) -> tuple[int, int, bytes, int, int]:
    rect = wintypes.RECT()
    window_rect = wintypes.RECT()
    origin = wintypes.POINT()
    if not user32.GetClientRect(hwnd, ctypes.byref(rect)) or not user32.ClientToScreen(hwnd, ctypes.byref(origin)) or not user32.GetWindowRect(hwnd, ctypes.byref(window_rect)):
        raise ctypes.WinError(ctypes.get_last_error())
    width = rect.right - rect.left
    height = rect.bottom - rect.top
    if width <= 0 or height <= 0:
        raise RuntimeError("test window has an empty client area")
    frame_x = origin.x - window_rect.left
    frame_y = origin.y - window_rect.top

    screen = user32.GetDC(None)
    if not screen:
        raise ctypes.WinError(ctypes.get_last_error())
    memory = None
    bitmap = None
    previous = None
    try:
        memory = gdi32.CreateCompatibleDC(screen)
        if not memory:
            raise ctypes.WinError(ctypes.get_last_error())
        bitmap = gdi32.CreateCompatibleBitmap(screen, width, height)
        if not bitmap:
            raise ctypes.WinError(ctypes.get_last_error())
        previous = gdi32.SelectObject(memory, bitmap)
        if not previous:
            raise ctypes.WinError(ctypes.get_last_error())
        if not user32.PrintWindow(hwnd, memory, 2):
            raise ctypes.WinError(ctypes.get_last_error())
        info = BITMAPINFO()
        info.bmiHeader.biSize = ctypes.sizeof(BITMAPINFOHEADER)
        info.bmiHeader.biWidth = width
        info.bmiHeader.biHeight = -height
        info.bmiHeader.biPlanes = 1
        info.bmiHeader.biBitCount = 32
        info.bmiHeader.biCompression = BI_RGB
        pixels = ctypes.create_string_buffer(width * height * 4)
        rows = gdi32.GetDIBits(memory, bitmap, 0, height, pixels, ctypes.byref(info), DIB_RGB_COLORS)
        if rows != height:
            raise ctypes.WinError(ctypes.get_last_error())
        return width, height, pixels.raw, frame_x, frame_y
    finally:
        if previous is not None:
            gdi32.SelectObject(memory, previous)
        if bitmap is not None:
            gdi32.DeleteObject(bitmap)
        if memory is not None:
            gdi32.DeleteDC(memory)
        user32.ReleaseDC(None, screen)


def line_ink(pixels: bytes, width: int, height: int, line: int, frame_x: int, frame_y: int) -> int:
    count = 0
    top = frame_y + 24 + round(line * 22.4)
    for y in range(top, min(top + 19, height)):
        for x in range(frame_x + 4, min(frame_x + 790, width)):
            offset = (y * width + x) * 4
            blue, green, red = pixels[offset:offset + 3]
            if max(red, green, blue) > 80:
                count += 1
    return count


def write_png(path: Path, width: int, height: int, pixels: bytes) -> None:
    rows = bytearray()
    for y in range(height):
        rows.append(0)
        for x in range(width):
            offset = (y * width + x) * 4
            blue, green, red = pixels[offset:offset + 3]
            rows.extend((red, green, blue))

    def chunk(kind: bytes, payload: bytes) -> bytes:
        return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", zlib.crc32(kind + payload) & 0xFFFFFFFF)

    png = b"\x89PNG\r\n\x1a\n"
    png += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 2, 0, 0, 0))
    png += chunk(b"IDAT", zlib.compress(bytes(rows), 6))
    png += chunk(b"IEND", b"")
    path.write_bytes(png)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--binary", required=True, type=Path)
    parser.add_argument("--screenshot", type=Path)
    parser.add_argument("--timeout", type=float, default=20.0)
    args = parser.parse_args()
    if not 1.0 <= args.timeout <= 60.0:
        parser.error("--timeout must be between 1 and 60 seconds")
    binary = args.binary.resolve()
    if not binary.is_file():
        parser.error("--binary must name the test executable")

    sandbox = Path(tempfile.mkdtemp(prefix="hammer-windows-text-"))
    process: subprocess.Popen[bytes] | None = None
    succeeded = False
    log_path = sandbox / "hammer.log"
    try:
        sample = sandbox / "sample.txt"
        sample.write_bytes(("\n".join(LINES)).encode("utf-8"))
        environment = os.environ.copy()
        environment["HAMMER_LOG"] = ""
        environment["HAMMER_AUTOQUIT_FRAMES"] = "600"
        with log_path.open("wb") as log:
            process = subprocess.Popen([str(binary), str(sample)], stdin=subprocess.DEVNULL, stdout=log, stderr=subprocess.STDOUT, env=environment)
            hwnd = find_window(process.pid, args.timeout)
            user32.SetWindowPos(hwnd, 0, 0, 0, 0, 0, 1)
            time.sleep(0.7)
            if process.poll() is not None:
                raise RuntimeError(f"hammer exited early with {process.returncode}")
            width, height, pixels, frame_x, frame_y = capture_window(hwnd)
            ink = [line_ink(pixels, width, height, line, frame_x, frame_y) for line in range(len(LINES))]
            if args.screenshot:
                args.screenshot.parent.mkdir(parents=True, exist_ok=True)
                write_png(args.screenshot, width, height, pixels)
            if any(count < 100 for count in ink):
                raise RuntimeError(f"one or more text lines have insufficient visible ink: {ink}")
            print(f"Windows text ink by line: {ink}")
        process.wait(timeout=args.timeout)
        if process.returncode != 0:
            raise RuntimeError(f"hammer exited with {process.returncode}")
        if "render-text:" in log_path.read_text(errors="replace"):
            raise RuntimeError("hammer reported a text rendering error")
        succeeded = True
        return 0
    finally:
        if process is not None:
            try:
                process.wait(timeout=args.timeout)
            except subprocess.TimeoutExpired:
                process.terminate()
                process.wait(timeout=5)
        if not succeeded:
            print(log_path.read_text(errors="replace"), file=sys.stderr)
        shutil.rmtree(sandbox)


if __name__ == "__main__":
    sys.exit(main())
