"""Check Windows TUI scroll memory across two visits in one Lush process.

Run: python tests/tui_memory.py --exe build/lush.exe
"""

from __future__ import annotations

import argparse
import ctypes as ct
from ctypes import wintypes as wt
import os
from pathlib import Path
import re
import sys
import tempfile
import time

from integration import ROOT, lua_string
from tui_cursor import Pseudoconsole


class MemoryCounters(ct.Structure):
    _fields_ = [
        ("size", wt.DWORD), ("page_faults", wt.DWORD),
        *[(name, ct.c_size_t) for name in (
            "peak_working_set", "working_set", "peak_paged", "paged",
            "peak_nonpaged", "nonpaged", "pagefile", "peak_pagefile", "private",
        )],
    ]


def wait_for(terminal, pattern):
    output = b""
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        output = output[-4096:] + terminal.receive()
        match = re.search(pattern, output)
        if match:
            return match
        assert terminal.poll() is None, output[-1000:]
    raise AssertionError((pattern, output[-1000:]))


def check(executable):
    kernel = ct.WinDLL("kernel32", use_last_error=True)
    kernel.OpenProcess.argtypes = [wt.DWORD, wt.BOOL, wt.DWORD]
    kernel.OpenProcess.restype = wt.HANDLE
    kernel.CloseHandle.argtypes = [wt.HANDLE]
    query = ct.WinDLL("psapi", use_last_error=True).GetProcessMemoryInfo
    query.argtypes = [wt.HANDLE, ct.POINTER(MemoryCounters), wt.DWORD]

    def private_bytes(process):
        info = MemoryCounters()
        info.size = ct.sizeof(info)
        if not query(process, ct.byref(info), info.size):
            raise ct.WinError(ct.get_last_error())
        return info.private

    # The ConPTY helper also starts a Python wrapper. Ask a direct Lush child
    # for its parent PID so we sample the shell that owns the browser.
    code = (
        f"local r=capture(cmd[ {lua_string(sys.executable)} ]('-c','import os; print(os.getppid())')); "
        "print('LUSH_PID='..assert(tonumber(r.stdout))..';'); io.read(); "
        "for i=1,2 do show(ls('--tui')); print('CLOSED'..i); io.read() end"
    )
    with tempfile.TemporaryDirectory(prefix="lush-scroll-") as temporary:
        directory = Path(temporary)
        for i in range(64):
            child = directory / f"dir-{i:02}"
            child.mkdir()
            (child / "preview.txt").touch()
        terminal = Pseudoconsole(executable, code, 132, 36, cwd=directory)
        process = None
        try:
            pid = int(wait_for(terminal, rb"LUSH_PID=(\d+);")[1])
            process = kernel.OpenProcess(0x0400 | 0x0010, False, pid)
            if not process:
                raise ct.WinError(ct.get_last_error())
            initial = private_bytes(process)
            scrolling, closed = [], []
            for visit in (1, 2):
                terminal.send(b"\r")
                wait_for(terminal, b"1/64")
                down, up = (b"j", b"k") if visit == 1 else (b"\x1b[<65;10;5M", b"\x1b[<64;10;5M")
                for _ in range(4):
                    # An empty create prompt acknowledges that all preceding
                    # input events were processed. Enter dismisses it.
                    terminal.send((down * 32 + up * 32) * 2 + b"n")
                    wait_for(terminal, b"end with /")
                    scrolling.append(private_bytes(process))
                    terminal.send(b"\r")
                terminal.send(b"q")
                wait_for(terminal, f"CLOSED{visit}".encode())
                closed.append(private_bytes(process))

            # Allow committed heap pages to vary after the first warm redraws.
            # The leak retained over 16 MiB over this input sequence.
            slack = 6 * 1024**2
            samples = {"initial": initial, "scrolling": scrolling, "closed": closed}
            assert max(scrolling) - scrolling[0] <= slack, samples
            assert max(closed) - initial <= slack, samples
            terminal.send(b"\r")
            deadline = time.monotonic() + 10
            while terminal.poll() is None and time.monotonic() < deadline:
                terminal.receive()
            assert terminal.poll() == 0, "Lush failed to exit cleanly"
            print("TUI scroll memory checks passed (private MiB before / peak / after):",
                  *(round(n / 1024**2, 1) for n in (initial, max(scrolling), closed[-1])))
        finally:
            if process:
                kernel.CloseHandle(process)
            terminal.close()


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=ROOT / "build/lush.exe")
    args = parser.parse_args()
    if os.name == "nt":
        check(args.exe.resolve(strict=True))
    else:
        print("SKIP: Windows ConPTY memory check")
