#!/usr/bin/env python3
"""Check editable TUI cursor ordering from a Windows ConPTY VT transcript.

The pseudoconsole has no visible window and receives no desktop pointer input.
Run: python tests/tui_cursor.py --exe build/lush.exe
"""

from __future__ import annotations

import argparse
import codecs
import ctypes as ct
from ctypes import wintypes as wt
import json
import os
from pathlib import Path
import queue
import subprocess
import sys
import tempfile
import threading
import time
import unicodedata


class Pseudoconsole:
    def __init__(self, executable: Path, code: str | None, columns: int, rows: int, *,
                 config_path: Path | None = None, history_file: Path | str | None = None,
                 environment: dict[str, str] | None = None, cwd: Path | None = None):
        kernel = self.kernel = ct.WinDLL("kernel32", use_last_error=True)

        class Coord(ct.Structure):
            _fields_ = [("x", ct.c_short), ("y", ct.c_short)]

        class Startup(ct.Structure):
            _fields_ = [("cb", wt.DWORD), ("reserved", wt.LPWSTR), ("desktop", wt.LPWSTR),
                        ("title", wt.LPWSTR), ("x", wt.DWORD), ("y", wt.DWORD),
                        ("width", wt.DWORD), ("height", wt.DWORD),
                        ("chars_x", wt.DWORD), ("chars_y", wt.DWORD),
                        ("fill", wt.DWORD), ("flags", wt.DWORD),
                        ("show", wt.WORD), ("reserved_size", wt.WORD),
                        ("reserved_bytes", ct.POINTER(ct.c_byte)),
                        ("stdin", wt.HANDLE), ("stdout", wt.HANDLE), ("stderr", wt.HANDLE)]

        class StartupEx(ct.Structure):
            _fields_ = [("startup", Startup), ("attributes", ct.c_void_p)]

        class ProcessInfo(ct.Structure):
            _fields_ = [("process", wt.HANDLE), ("thread", wt.HANDLE),
                        ("process_id", wt.DWORD), ("thread_id", wt.DWORD)]

        kernel.CreatePipe.argtypes = [ct.POINTER(wt.HANDLE), ct.POINTER(wt.HANDLE), ct.c_void_p, wt.DWORD]
        kernel.CreatePseudoConsole.argtypes = [Coord, wt.HANDLE, wt.HANDLE, wt.DWORD, ct.POINTER(wt.HANDLE)]
        kernel.CreatePseudoConsole.restype = ct.c_long
        kernel.ClosePseudoConsole.argtypes = [wt.HANDLE]
        kernel.InitializeProcThreadAttributeList.argtypes = [ct.c_void_p, wt.DWORD, wt.DWORD,
                                                            ct.POINTER(ct.c_size_t)]
        kernel.UpdateProcThreadAttribute.argtypes = [ct.c_void_p, wt.DWORD, ct.c_size_t, ct.c_void_p,
                                                    ct.c_size_t, ct.c_void_p, ct.c_void_p]
        kernel.DeleteProcThreadAttributeList.argtypes = [ct.c_void_p]
        kernel.CreateProcessW.argtypes = [wt.LPCWSTR, wt.LPWSTR, ct.c_void_p, ct.c_void_p,
                                         wt.BOOL, wt.DWORD, ct.c_void_p, wt.LPCWSTR,
                                         ct.POINTER(StartupEx), ct.POINTER(ProcessInfo)]
        kernel.ReadFile.argtypes = [wt.HANDLE, ct.c_void_p, wt.DWORD, ct.POINTER(wt.DWORD), ct.c_void_p]
        kernel.WriteFile.argtypes = kernel.ReadFile.argtypes
        kernel.GetExitCodeProcess.argtypes = [wt.HANDLE, ct.POINTER(wt.DWORD)]
        kernel.TerminateProcess.argtypes = [wt.HANDLE, wt.UINT]
        kernel.WaitForSingleObject.argtypes = [wt.HANDLE, wt.DWORD]
        kernel.CloseHandle.argtypes = [wt.HANDLE]
        self.handles, self.console, self.process = [], None, None
        self.chunks: queue.Queue[bytes] = queue.Queue()
        self.reader_error: Exception | None = None
        self.reader = None
        # Interactive tests must never load or append to the real user's
        # configuration/history, and older editor tests expect no ghost text.
        self.fixture = tempfile.TemporaryDirectory(prefix="lush-pty-session-")
        fixture_root = Path(self.fixture.name)
        if config_path is None:
            config_path = fixture_root / "init.lua"
            config_path.write_text("lush.config.autosuggestions = false\n", encoding="utf-8")
        child_environment = dict(os.environ)
        child_environment["LUSH_HISTORY_FILE"] = str(
            fixture_root / "history.jsonl" if history_file is None else history_file,
        )
        child_environment.update(environment or {})
        environment_text = "\0".join(f"{name}={value}" for name, value in
                                      sorted(child_environment.items(), key=lambda item: item[0].upper())) + "\0\0"
        environment_block = ct.create_unicode_buffer(environment_text)
        try:
            input_read, self.input_write = wt.HANDLE(), wt.HANDLE()
            self.output_read, output_write = wt.HANDLE(), wt.HANDLE()
            self.checked(kernel.CreatePipe(ct.byref(input_read), ct.byref(self.input_write), None, 0), "input pipe")
            self.handles += [input_read, self.input_write]
            self.checked(kernel.CreatePipe(ct.byref(self.output_read), ct.byref(output_write), None, 0), "output pipe")
            self.handles += [self.output_read, output_write]
            console = wt.HANDLE()
            status = kernel.CreatePseudoConsole(Coord(columns, rows), input_read, output_write, 0, ct.byref(console))
            if status < 0:
                raise OSError(status, "CreatePseudoConsole")
            self.console = console
            attribute_size = ct.c_size_t()
            kernel.InitializeProcThreadAttributeList(None, 1, 0, ct.byref(attribute_size))
            attributes = ct.create_string_buffer(attribute_size.value)
            self.checked(kernel.InitializeProcThreadAttributeList(attributes, 1, 0, ct.byref(attribute_size)),
                         "InitializeProcThreadAttributeList")
            try:
                self.checked(kernel.UpdateProcThreadAttribute(attributes, 0, 0x00020016, console,
                                                             ct.sizeof(wt.HANDLE), None, None),
                             "pseudoconsole attribute")
                startup = StartupEx()
                startup.startup.cb = ct.sizeof(startup)
                startup.attributes = ct.cast(attributes, ct.c_void_p)
                process = ProcessInfo()
                # A desktop app can start Python with redirected standard
                # handles. Reopen the newly attached pseudoconsole explicitly
                # so those parent pipes cannot leak into the application.
                wrapper = (
                    "import os,subprocess,sys; "
                    "i=os.open('CONIN$',os.O_RDWR|os.O_BINARY); "
                    "o=os.open('CONOUT$',os.O_RDWR|os.O_BINARY); "
                    "sys.exit(subprocess.call(sys.argv[1:],stdin=i,stdout=o,stderr=o))"
                )
                arguments = [str(executable), "--config", str(config_path)]
                if code is not None:
                    arguments += ["-c", code]
                command = ct.create_unicode_buffer(subprocess.list2cmdline(
                    [sys.executable, "-c", wrapper, *arguments],
                ))
                self.checked(kernel.CreateProcessW(sys.executable, command, None, None, False,
                                                   0x00080000 | 0x00000400,
                                                   ct.cast(environment_block, ct.c_void_p),
                                                   str(cwd or executable.parent),
                                                   ct.byref(startup), ct.byref(process)), "CreateProcessW")
                self.process = process.process
                kernel.CloseHandle(process.thread)
            finally:
                kernel.DeleteProcThreadAttributeList(attributes)
            self.reader = threading.Thread(target=self.read_output, daemon=True)
            self.reader.start()
        except BaseException:
            self.close()
            raise

    @staticmethod
    def checked(success, operation):
        if not success:
            raise OSError(ct.get_last_error(), operation)

    def read_output(self):
        buffer = ct.create_string_buffer(65536)
        try:
            while True:
                count = wt.DWORD()
                if not self.kernel.ReadFile(self.output_read, buffer, len(buffer), ct.byref(count), None):
                    if ct.get_last_error() not in (6, 109, 995):
                        raise OSError(ct.get_last_error(), "ReadFile pseudoconsole")
                    return
                if not count.value:
                    return
                self.chunks.put(buffer.raw[:count.value])
        except Exception as error:
            self.reader_error = error

    def poll(self):
        result = wt.DWORD()
        self.checked(self.kernel.GetExitCodeProcess(self.process, ct.byref(result)), "GetExitCodeProcess")
        return None if result.value == 259 else result.value

    def send(self, data: bytes):
        buffer = ct.create_string_buffer(data)
        count = wt.DWORD()
        self.checked(self.kernel.WriteFile(self.input_write, buffer, len(data), ct.byref(count), None),
                     "WriteFile pseudoconsole")
        assert count.value == len(data)

    def receive(self, timeout=.05):
        if self.reader_error:
            raise self.reader_error
        try:
            return self.chunks.get(timeout=timeout)
        except queue.Empty:
            return b""

    def close(self):
        if self.process:
            if self.poll() is None:
                self.kernel.TerminateProcess(self.process, 1)
                self.kernel.WaitForSingleObject(self.process, 3000)
            self.kernel.CloseHandle(self.process)
            self.process = None
        if self.console:
            self.kernel.ClosePseudoConsole(self.console)
            self.console = None
        for handle in reversed(self.handles):
            self.kernel.CloseHandle(handle)
        self.handles.clear()
        if self.reader:
            self.reader.join(timeout=1)
        self.fixture.cleanup()


class Transcript:
    """Track just the VT controls relevant to caret visibility and placement."""

    def __init__(self, columns, rows):
        self.columns, self.rows = columns, rows
        self.x = self.y = 0
        self.visible, self.alternate = True, False
        self.state, self.sequence = "text", ""
        self.decoder = codecs.getincrementaldecoder("utf-8")("replace")
        self.raw = bytearray()
        self.shows = []
        self.paint_while_visible = []

    def painted(self, value):
        if self.alternate and self.visible:
            self.paint_while_visible.append((self.x, self.y, value))

    def control(self, final):
        sequence = self.sequence
        if sequence.startswith("?"):
            modes = sequence[1:].split(";")
            if final in "hl" and "25" in modes:
                self.visible = final == "h"
                if self.visible and self.alternate:
                    self.shows.append((self.x, self.y))
            if final in "hl" and "1049" in modes:
                self.alternate = final == "h"
                self.x = self.y = 0
            return
        try:
            values = [int(value or 0) for value in sequence.split(";")]
        except ValueError:
            return
        first = values[0] if values else 0
        if final in "Hf":
            self.y = max(0, (first or 1) - 1)
            self.x = max(0, ((values[1] if len(values) > 1 else 1) or 1) - 1)
        elif final == "G": self.x = max(0, (first or 1) - 1)
        elif final == "d": self.y = max(0, (first or 1) - 1)
        elif final == "A": self.y = max(0, self.y - (first or 1))
        elif final == "B": self.y = min(self.rows - 1, self.y + (first or 1))
        elif final == "C": self.x = min(self.columns - 1, self.x + (first or 1))
        elif final == "D": self.x = max(0, self.x - (first or 1))
        elif final in "JKXP@": self.painted("CSI " + sequence + final)

    def feed(self, data):
        self.raw.extend(data)
        for value in self.decoder.decode(data):
            if self.state == "osc":
                if value == "\a": self.state = "text"
                elif value == "\x1b": self.state = "osc_escape"
                continue
            if self.state == "osc_escape":
                self.state = "text" if value == "\\" else "osc"
                continue
            if self.state == "escape":
                if value == "[": self.state, self.sequence = "csi", ""
                elif value == "]": self.state = "osc"
                else: self.state = "text"
                continue
            if self.state == "csi":
                if "@" <= value <= "~":
                    self.control(value)
                    self.state = "text"
                else: self.sequence += value
                continue
            if value == "\x1b": self.state = "escape"
            elif value == "\r": self.x = 0
            elif value == "\n": self.y = min(self.rows - 1, self.y + 1)
            elif value == "\b": self.x = max(0, self.x - 1)
            elif value == "\t": self.x = min(self.columns - 1, (self.x // 8 + 1) * 8)
            elif ord(value) >= 32:
                self.painted(value)
                width = 0 if unicodedata.combining(value) else (
                    2 if unicodedata.east_asian_width(value) in ("W", "F") else 1
                )
                self.x = min(self.columns - 1, self.x + width)


def check(executable):
    columns, rows = 100, 30
    with tempfile.TemporaryDirectory(prefix="lush-tui-cursor-") as temporary:
        root = Path(temporary)
        for name in ("alpha.txt", "another.txt", "beta.txt"):
            (root / name).touch()
        code = "show(ls('--tui', " + json.dumps(str(root)) + "))"
        terminal = Pseudoconsole(executable, code, columns, rows)
        transcript = Transcript(columns, rows)
        monitor_paint = False

        def until(predicate, description):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                transcript.feed(terminal.receive())
                if monitor_paint:
                    assert not transcript.paint_while_visible, (
                        "TUI painted while its text cursor was visible",
                        transcript.paint_while_visible[:8],
                    )
                if predicate():
                    return
                assert terminal.poll() is None, ("TUI exited", terminal.poll(), bytes(transcript.raw[-1000:]))
            raise AssertionError((description, bytes(transcript.raw[-1500:])))

        def expect_edit(data, column):
            before = len(transcript.shows)
            terminal.send(data)
            until(lambda: len(transcript.shows) > before, "editable frame did not reveal its caret")
            assert transcript.shows[before] == (column - 1, rows - 1), (
                "caret was revealed before positioning in the active field",
                transcript.shows[before], (column - 1, rows - 1),
            )
            assert not transcript.paint_while_visible, (
                "TUI painted while its text cursor was visible",
                transcript.paint_while_visible[:8],
            )

        try:
            until(lambda: b"1/3" in transcript.raw, "initial TUI frame missing")
            # ConPTY's initial switch to its alternate buffer can publish a
            # transient cursor state. Exercise the application's settled edit
            # loop, which must hide before every subsequent repaint.
            empty = 0
            while empty < 2:
                data = terminal.receive()
                transcript.feed(data)
                empty = 0 if data else empty + 1
            transcript.shows.clear()
            transcript.paint_while_visible.clear()
            monitor_paint = True
            expect_edit(b"/", 3)
            expect_edit(b"a", 4)
            expect_edit(b"l", 5)
            expect_edit(b"\x7f", 4)
            terminal.send(b"\x1b")
            until(lambda: not transcript.visible, "leaving filter did not hide its caret")
            expect_edit(b"c", 6)  # Status label is 'cd: ', beginning in column 2.
            expect_edit(b"x", 7)
            expect_edit(b"\x7f", 6)
            terminal.send(b"\x1b")
            until(lambda: not transcript.visible, "leaving directory input did not hide its caret")
            terminal.send(b"q")
            until(lambda: terminal.poll() is not None, "TUI did not exit")
            assert terminal.poll() == 0
            assert not transcript.paint_while_visible, transcript.paint_while_visible[:8]
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    args = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows ConPTY cursor transcript")
        return
    check(args.exe.resolve(strict=True))
    print("TUI cursor checks passed: hidden painting and positioned filter/directory carets")


if __name__ == "__main__":
    main()
