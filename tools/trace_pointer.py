"""Record pointer position/visibility while running Lush's animation on Windows.

Run in the affected terminal: python tools/trace_pointer.py
Reads pointer information only: no pointer moves, hooks, or Windows setting changes.
The trace contains timestamps, coordinates, visibility, and cursor handles; no keys.
"""

from __future__ import annotations

import argparse
import csv
import ctypes as ct
from ctypes import wintypes as wt
from pathlib import Path
import subprocess
import sys
import threading
import time


ROOT = Path(__file__).resolve().parents[1]


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=ROOT / "build/lush.exe")
    parser.add_argument("--output", type=Path, default=ROOT / "build/pointer-trace.csv")
    parser.add_argument("--source", default="show(sl('--lol=signal'))")
    args = parser.parse_args()
    if sys.platform != "win32":
        parser.error("this diagnostic uses Windows pointer queries")
    executable = args.exe.resolve(strict=True)
    output = args.output.resolve()
    output.parent.mkdir(parents=True, exist_ok=True)

    class CursorInfo(ct.Structure):
        _fields_ = [("size", wt.DWORD), ("flags", wt.DWORD),
                    ("cursor", wt.HANDLE), ("position", wt.POINT)]

    user = ct.WinDLL("user32", use_last_error=True)
    user.GetCursorInfo.argtypes = [ct.POINTER(CursorInfo)]
    user.GetCursorInfo.restype = wt.BOOL
    stop = threading.Event()
    phase = ["before"]
    samples: list[tuple] = []
    failures: list[int] = []
    started = time.perf_counter()

    def sample() -> None:
        deadline = time.perf_counter()
        while not stop.is_set():
            info = CursorInfo()
            info.size = ct.sizeof(info)
            now = time.perf_counter()
            if user.GetCursorInfo(ct.byref(info)):
                samples.append((round(now - started, 6), phase[0], info.position.x,
                                info.position.y, info.flags, int(info.cursor or 0)))
            else:
                failures.append(ct.get_last_error())
            deadline += .005
            # Resynchronize after a scheduling stall rather than busy catching up.
            if deadline < time.perf_counter():
                deadline = time.perf_counter() + .005
            stop.wait(max(0, deadline - time.perf_counter()))

    print("Move the pointer as usual during the animation; Ctrl+C stops the animation.", flush=True)
    worker = threading.Thread(target=sample, name="pointer-query", daemon=True)
    worker.start()
    code = 1
    try:
        time.sleep(.5)
        phase[0] = "animation"
        code = subprocess.call([str(executable), "--no-config", "-c", args.source])
        phase[0] = "after"
        time.sleep(.5)
    finally:
        stop.set()
        worker.join(timeout=2)
        with output.open("w", encoding="utf-8", newline="") as stream:
            writer = csv.writer(stream)
            writer.writerow(("seconds", "phase", "screen_x", "screen_y", "cursor_flags", "cursor_handle"))
            writer.writerows(samples)
        print(f"Pointer trace: {output} ({len(samples)} samples)")
        if failures:
            print(f"Pointer queries failed {len(failures)} times; Windows error {failures[0]}")
    return code


if __name__ == "__main__":
    raise SystemExit(main())
