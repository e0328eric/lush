#!/usr/bin/env python3
"""Check Windows TUI default opening without launching user applications.

Run: python tests/tui_open.py --exe build/lush.exe
Snapshots test opener selection; a hidden ConPTY tests opening and quitting in a subdirectory.
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time

from integration import ROOT, lua_string
from tui_cursor import Pseudoconsole


def check(executable: Path) -> None:
    environment = dict(os.environ, FLS_OPENER="", NNN_OPENER="")
    with tempfile.TemporaryDirectory(prefix="lush-tui-open-") as temporary:
        directory = Path(temporary)
        target = directory / "literal 한글 ; & $ ' percent%.txt"
        target.write_text("fixture", encoding="utf-8")

        def snapshot(keys="<Enter>", **overrides):
            arguments = ["--snapshot", "--keys", keys, "--width", "240", str(directory)]
            listing = "show(ls(" + ",".join(lua_string(arg) for arg in arguments) + "))"
            code = "local before = pwd(); " + listing + "; assert(pwd() == before)"
            result = subprocess.run([str(executable), "--no-config", "-c", code],
                                    cwd=directory, env=environment | overrides,
                                    capture_output=True, text=True, encoding="utf-8", timeout=20)
            assert result.returncode == 0 and not result.stderr, result
            return result.stdout

        output = snapshot()
        assert "would open: " in output and target.name in output, output
        assert "xdg-open" not in output and "would run:" not in output, output
        output = snapshot(FLS_OPENER="fls-opener-test", NNN_OPENER="nnn-opener-test")
        assert "would run: fls-opener-test " in output and "nnn-opener-test" not in output, output
        output = snapshot(NNN_OPENER="nnn-opener-test")
        assert "would run: nnn-opener-test " in output and "would open:" not in output, output

        child = directory / "subdirectory"
        child.mkdir()
        nested = child / "nested.txt"
        nested.write_text("nested fixture", encoding="utf-8")
        output = snapshot("/subdirectory<Enter>")
        assert nested.name in output and "would open:" not in output and "would run:" not in output, output
        output = snapshot("/subdirectory<Enter>h")
        assert target.name in output and child.name in output and "would open:" not in output, output

        expected = lua_string(child.as_posix())
        code = f"show(ls('--tui')); assert(pwd():lower() == string.lower({expected}), pwd())"
        terminal = Pseudoconsole(executable, code, 180, 30, environment=environment, cwd=directory)
        transcript = bytearray()

        def until(predicate, description):
            deadline = time.monotonic() + 10
            while time.monotonic() < deadline:
                transcript.extend(terminal.receive())
                if predicate():
                    return
                assert terminal.poll() is None, (description, terminal.poll(), bytes(transcript[-2000:]))
            raise AssertionError((description, bytes(transcript[-2000:])))

        try:
            until(lambda: b"1/2" in transcript, "initial file listing missing")
            terminal.send(b"\r")
            until(lambda: b"1/1" in transcript, "did not enter the subdirectory")
            # Keep the cached entry selected until Enter. Restoring the directory
            # timestamp prevents the idle refresh from discarding the removed file.
            timestamps = child.stat()
            nested.unlink()
            os.utime(child, ns=(timestamps.st_atime_ns, timestamps.st_mtime_ns))
            terminal.send(b"\r")
            until(lambda: b"open: " in transcript, "native opener failure missing")
            assert b"Win32 error" in transcript or b"shell error" in transcript, bytes(transcript[-2000:])
            assert b"xdg-open" not in transcript, bytes(transcript[-2000:])
            terminal.send(b"q")
            until(lambda: terminal.poll() is not None, "browser did not exit after opener failure")
            assert terminal.poll() == 0, bytes(transcript[-2000:])
        finally:
            terminal.close()
    print("TUI checks passed: Windows default opener, override precedence, native errors and cwd on quit")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=ROOT / "build/lush.exe")
    arguments = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows TUI default opener")
        return
    check(arguments.exe.resolve(strict=True))


if __name__ == "__main__":
    main()
