#!/usr/bin/env python3
"""Generate static Acme/Sam compatibility fixtures without 9P or editor IPC."""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import re
import subprocess
import tempfile

OUTPUT = Path(__file__).resolve().parent / "fixtures" / "acme-edit.json"
RANGE = re.compile(r"^#(\d+)(?:,#(\d+))?$", re.MULTILINE)
TEXT = "zero\nαβ🙂\nthird\n\nlast"
LINES = "one\ntwo\nthree\n"

ADDRESSES = [
    {"name": "absolute Unicode line", "input": TEXT, "dot": [5, 9], "expression": "2"},
    {"name": "Unicode character offset", "input": TEXT, "dot": [0, 0], "expression": "#8"},
    {"name": "relative lines", "input": TEXT, "dot": [0, 0], "expression": "1+2"},
    {"name": "implicit forward characters", "input": TEXT, "dot": [0, 0], "expression": "1#2"},
    {"name": "comma range", "input": TEXT, "dot": [0, 0], "expression": "2,4"},
    {"name": "semicolon changes right dot", "input": TEXT, "dot": [0, 0], "expression": "2;+#1"},
    {"name": "leftmost longest alternative", "input": "alpha\nal\n", "dot": [0, 0], "expression": "/a|alpha/"},
    {"name": "forward regex wraps", "input": TEXT, "dot": [10, 15], "expression": "/zero/"},
    {"name": "backward regex", "input": "alpha\nbeta\ngamma\n", "dot": [17, 17], "expression": "?beta?"},
    {"name": "line start empty match advances", "input": "a\nb\n", "dot": [0, 0], "expression": "/^/"},
    {"name": "line end is zero width", "input": "a\nb\n", "dot": [0, 0], "expression": "/$/"},
    {"name": "empty regex match", "input": "bbb", "dot": [0, 0], "expression": "/a*/"},
    {"name": "backward empty regex wraps", "input": "bbb", "dot": [0, 0], "expression": "?x*?"},
    {"name": "final unterminated line", "input": TEXT, "dot": [0, 0], "expression": "5"},
    {"name": "regex no match", "input": TEXT, "dot": [0, 0], "expression": "/missing/", "error": "NotFound"},
]

EDITS = [
    {"name": "change with escaped newlines", "input": LINES, "dot": [0, 0], "command": "1c/first\\nsecond\\n/"},
    {"name": "append after line", "input": LINES, "dot": [0, 0], "command": "2a/ after/"},
    {"name": "insert before line", "input": LINES, "dot": [0, 0], "command": "2i/before /"},
    {"name": "delete line", "input": LINES, "dot": [0, 0], "command": "2d"},
    {"name": "multiline change", "input": LINES, "dot": [0, 0], "command": "2c\nX\nY\n."},
    {"name": "move range to end", "input": LINES, "dot": [0, 0], "command": "1,2m$", "acme_dot": [0, 0]},
    {"name": "move range to start", "input": LINES, "dot": [0, 4], "command": "2,3m0", "acme_dot": [0, 4]},
    {"name": "copy line to end", "input": LINES, "dot": [0, 0], "command": "1t$", "acme_dot": [0, 0]},
    {"name": "copy line to start", "input": LINES, "dot": [4, 8], "command": "2t0", "acme_dot": [4, 8]},
    {"name": "commands use intermediate text", "input": LINES, "dot": [0, 0], "command": "1d\n1c/X/"},
    {"name": "substitute leftmost longest", "input": "alpha al alpha\n", "dot": [0, 0], "command": ",s/a|alpha/X/g"},
    {"name": "substitute second match", "input": LINES, "dot": [0, 0], "command": ",s2/[a-z]+/X/"},
    {"name": "substitute all words", "input": LINES, "dot": [0, 0], "command": ",s/[a-z]+/X/g"},
    {"name": "capture and unmatched group", "input": "a al\n", "dot": [0, 0], "command": ",s/(a)(l)?/[\\1][\\2]/g", "acme_dot": [0, 5]},
    {"name": "full match replacement", "input": "a b a\n", "dot": [0, 0], "command": ",s/a/[&]/g", "acme_dot": [0, 6]},
    {"name": "empty match substitution", "input": "bbb", "dot": [0, 0], "command": ",s/x*/-/g", "acme_dot": [0, 3]},
    {"name": "Unicode substitution", "input": "αβ αβ\n", "dot": [0, 0], "command": ",s/β/🙂/g", "acme_dot": [0, 6]},
    {"name": "addressed substitution", "input": LINES, "dot": [0, 0], "command": "2s/two/2/", "acme_dot": [4, 8]},
    {"name": "substitution no match", "input": LINES, "dot": [0, 0], "command": ",s/zzz/X/", "error": "NotFound"},
    {"name": "runtime error keeps prefix", "input": LINES, "dot": [0, 0], "command": "0a/new/\n99d", "error": "NotFound"},
]


def byte_offset(text: str, rune_offset: int) -> int:
    return len(text[:rune_offset].encode("utf-8"))


def byte_range(text: str, offsets: list[int]) -> list[int]:
    return [byte_offset(text, offsets[0]), byte_offset(text, offsets[1])]


def reference(case: dict, sam: str, address: bool) -> tuple[list[int], str]:
    with tempfile.TemporaryDirectory(prefix="hammer-acme-fixture-") as directory:
        path = Path(directory) / "input"
        path.write_text(case["input"], encoding="utf-8")
        dot = case["dot"]
        dot_command = f"#{dot[0]}" if dot[0] == dot[1] else f"#{dot[0]},#{dot[1]}"
        operation = case["expression"] + "=#" if address else case["command"]
        script = f"{dot_command}\n{operation}\n"
        if not address:
            script += "=#\nw input\n"
        script += "q\n"
        result = subprocess.run(
            [sam, "-d", "input"],
            cwd=directory,
            input=script,
            text=True,
            capture_output=True,
            timeout=10,
            check=False,
        )
        if result.returncode != 0:
            raise RuntimeError(f"{case['name']}: sam exited {result.returncode}: {result.stderr}")
        errors = [line for line in result.stderr.splitlines() if line.startswith("?")]
        if bool(errors) != bool(case.get("error")):
            raise RuntimeError(f"{case['name']}: unexpected reference diagnostics: {errors}")
        matches = RANGE.findall(result.stderr)
        content = path.read_text(encoding="utf-8")
        if not matches and errors and address:
            return byte_range(content, dot), content
        if not matches:
            raise RuntimeError(f"{case['name']}: cannot identify result range: {result.stderr!r}")
        start, end = matches[0]
        runes = [int(start), int(end) if end else int(start)]
        return byte_range(content, runes), content


def generate(sam: str) -> dict:
    addresses = []
    for case in ADDRESSES:
        want, _ = reference(case, sam, True)
        fixture = {key: value for key, value in case.items() if key != "expression"}
        fixture["dot"] = byte_range(case["input"], case["dot"])
        fixture["expression"] = case["expression"]
        fixture["want"] = want
        addresses.append(fixture)
    edits = []
    for case in EDITS:
        want, content = reference(case, sam, False)
        fixture = dict(case)
        acme_dot = fixture.pop("acme_dot", None)
        fixture["dot"] = byte_range(case["input"], case["dot"])
        fixture["want_content"] = content
        fixture["want"] = byte_range(case["input"], acme_dot) if acme_dot is not None else want
        edits.append(fixture)
    return {
        "reference": "Plan 9port sam -d; Acme ecmd.c dot overrides; no 9P",
        "offsets": "UTF-8 byte offsets converted from reference character offsets",
        "addresses": addresses,
        "edits": edits,
    }


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--sam", default="sam", help="Plan 9port sam executable")
    parser.add_argument("--output", type=Path, default=OUTPUT)
    parser.add_argument("--check", action="store_true", help="verify instead of rewriting the fixture")
    args = parser.parse_args()
    generated = json.dumps(generate(args.sam), ensure_ascii=False, indent=2) + "\n"
    if args.check:
        if not args.output.is_file() or args.output.read_text(encoding="utf-8") != generated:
            parser.error(f"{args.output} is not reproducible; run generate_fixtures.py")
        print(f"PASS: {len(ADDRESSES)} address and {len(EDITS)} edit fixtures reproduce with sam -d")
        return 0
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(generated, encoding="utf-8")
    print(f"wrote {len(ADDRESSES)} address and {len(EDITS)} edit fixtures to {args.output}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
