#!/usr/bin/env python3
"""Check Lua prompt colors as rendered VT cells, including editing and contexts."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import time

from history import HistoryTranscript, configuration, width
from tui_cursor import Pseudoconsole


PROMPT = "color> "


class Colors(HistoryTranscript):
    def __init__(self, columns, rows):
        super().__init__()
        self.columns, self.rows = columns, rows
        self.cells = [[" "] * columns for _ in range(rows)]
        self.dim_cells = [[False] * columns for _ in range(rows)]
        self.foreground = None
        self.foregrounds = [[None] * columns for _ in range(rows)]

    def painted(self, value):
        super().painted(value)
        if not value.startswith("CSI ") and 0 <= self.y < self.rows and 0 <= self.x < self.columns:
            self.foregrounds[self.y][self.x] = self.foreground
            if width(value) == 2 and self.x + 1 < self.columns:
                self.foregrounds[self.y][self.x + 1] = self.foreground

    def control(self, final):
        if final == "m":
            values = [int(value or 0) for value in self.sequence.split(";")]
            at = 0
            while at < len(values):
                value = values[at]
                if value in (0, 39): self.foreground = None
                elif 30 <= value <= 37 or 90 <= value <= 97: self.foreground = value
                elif value in (38, 48) and at + 1 < len(values):
                    count = 2 if values[at + 1] == 5 else 4
                    if value == 38 and at + count < len(values):
                        if count == 2:
                            index = values[at + 2]
                            self.foreground = 30 + index if index < 8 else 90 + index - 8 if index < 16 else ("indexed", index)
                        else: self.foreground = ("rgb", *values[at + 2:at + 5])
                    at += count
                at += 1
        super().control(final)


class Session:
    def __init__(self, executable, config, directory, columns=120):
        self.terminal = Pseudoconsole(executable, None, columns, 60, config_path=config,
                                     history_file=directory / "unused-default-history.jsonl", cwd=directory,
                                     environment={"TERM": "xterm-256color", "NO_COLOR": ""})
        self.trace = Colors(columns, 60)
        self.prompt = PROMPT
        self.ready()

    def receive(self, timeout=.04):
        data = self.terminal.receive(timeout)
        self.trace.feed(data)
        return data

    def until(self, predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            self.receive()
            if predicate(): return
            assert self.terminal.poll() is None, (self.terminal.poll(), bytes(self.trace.raw[-1000:]))
        raise AssertionError((description, self.trace.current_line(), self.trace.x, bytes(self.trace.raw[-1600:])))

    def settle(self):
        empty, deadline = 0, time.monotonic() + 3
        while empty < 2 and time.monotonic() < deadline:
            empty = 0 if self.receive() else empty + 1
        assert empty == 2

    def ready(self):
        self.until(lambda: self.trace.visible and self.trace.current_line() == PROMPT.rstrip() and
                   self.trace.x == len(PROMPT), "main prompt missing")
        self.prompt = PROMPT
        self.settle()

    def edit(self, data, source, caret=None, display=None):
        before = len(self.trace.raw)
        self.terminal.send(data.encode("utf-8") if isinstance(data, str) else data)
        caret = len(self.prompt) + width(source) if caret is None else caret
        expected = self.prompt + (source.replace("\n", "↵") if display is None else display)
        self.until(lambda: len(self.trace.raw) > before and self.trace.visible and self.trace.x == caret and
                   self.trace.current_line() == expected.rstrip(), "colored edit missing")
        self.settle()

    def color(self, source, token, expected, occurrence=0, *, dim=False):
        first = 0
        for _ in range(occurrence + 1):
            index = source.index(token, first)
            first = index + len(token)
        column = len(self.prompt) + width(source[:index])
        actual = self.trace.foregrounds[self.trace.y][column]
        assert actual == expected, (token, expected, actual, self.trace.current_line())
        assert self.trace.dim_cells[self.trace.y][column] == dim, ("incorrect dim style", token)

    def clear(self):
        self.terminal.send(b"\x05\x15")
        self.ready()

    def submit(self, source=None):
        before, row = len(self.trace.raw), self.trace.y
        if source is not None: self.terminal.send(source.encode("utf-8"))
        self.terminal.send(b"\r")
        self.until(lambda: len(self.trace.raw) > before and self.trace.y != row and
                   self.trace.current_line() == PROMPT.rstrip() and self.trace.x == len(PROMPT),
                   "submission did not return to the prompt")
        self.ready()
        return bytes(self.trace.raw[before:])

    def continue_line(self):
        before, row = len(self.trace.raw), self.trace.y
        self.terminal.send(b"\r")
        self.until(lambda: len(self.trace.raw) > before and self.trace.y != row and
                   self.trace.current_line() == "..." and self.trace.x == 4, "continuation prompt missing")
        self.prompt = "... "
        self.settle()

    def close(self):
        self.terminal.send(b"\x04")
        self.until(lambda: self.terminal.poll() is not None, "empty Ctrl+D did not exit")
        assert self.terminal.poll() == 0
        self.terminal.close()

    def __enter__(self): return self

    def __exit__(self, kind, value, traceback):
        if kind is None: self.close()
        else: self.terminal.close()


def config(root, name, **values):
    return configuration(root, name, prompt=PROMPT, history_file=False,
                         autosuggestions=False, **values)


def check(executable):
    with tempfile.TemporaryDirectory(prefix="lush-highlighting-") as temporary:
        root = Path(temporary)
        enabled = config(root, "enabled")  # The default highlighting setting is enabled.
        with Session(executable, enabled, root) as session:
            source = 'local label = "한글"; print(label, 42) -- note'
            session.edit(source, source)
            for token, color in (("local", 95), ("label", None), ("=", 94), ('"', 32),
                                 ("한", 32), ("print", 36), ("42", 33), ("--", 90), ("note", 90)):
                session.color(source, token, color)
            session.clear()
            source = 'print("bad\\q")'
            session.edit(source, source)
            session.color(source, "bad", 32)
            session.color(source, "\\q", 91)
            session.clear()

            session.edit('print("12")', 'print("12")')
            session.color('print("12")', "12", 32)
            session.edit(b"\x01" + b"\x1b[C" * 6 + b"\x1b[3~\x05" + b"\x1b[D" * 2 + b"\x1b[3~",
                         "print(12)", len(PROMPT) + 8)
            session.color("print(12)", "12", 33)
            session.clear()
            session.edit('print("한글")', 'print("한글")')
            session.edit(b"\x1b[D" * 3, 'print("한글")', len(PROMPT) + 9)
            session.edit("X", 'print("한X글")', len(PROMPT) + 10)
            session.edit(b"\x1b[3~", 'print("한X")', len(PROMPT) + 10)
            session.color('print("한X")', "한", 32)
            session.color('print("한X")', "X", 32)
            session.clear()

            recalled = "print('up-color', 23)"
            session.submit(recalled)
            session.edit(b"\x1b[A", recalled)
            session.color(recalled, "print", 36)
            session.color(recalled, "up-color", 32)
            session.color(recalled, "23", 33)
            before = len(session.trace.raw)
            session.terminal.send(b"\x0c")
            session.until(lambda: len(session.trace.raw) > before and session.trace.y == 0 and
                          session.trace.current_line() == PROMPT + recalled, "Ctrl+L lost highlighted input")
            session.settle()
            session.color(recalled, "23", 33)
            session.clear()

            session.edit("--[=[", "--[=[")
            session.continue_line()
            comment = "local 42 한글]=] local n = 5"
            session.edit(comment, comment)
            session.color(comment, "local", 90)
            session.color(comment, "42", 90)
            session.color(comment, "한", 90)
            session.color(comment, "local", 95, occurrence=1)
            session.color(comment, "5", 33)
            session.submit()
            session.edit("local s = [=[", "local s = [=[")
            session.continue_line()
            string = "local 42 한글]=]; local n = 3"
            session.edit(string, string)
            session.color(string, "local", 32)
            session.color(string, "42", 32)
            session.color(string, "한", 32)
            session.color(string, "local", 95, occurrence=1)
            session.color(string, "3", 33)
            session.submit()

            # Literal LF within one submitted chunk is displayed as a ↵ cell,
            # while its lexical class still comes from the original Lua source.
            prefix = "local s = [=["
            session.edit(prefix, prefix)
            literal = prefix + "\nlocal 42]=]"
            # ConPTY maps a bare LF to Enter; its negotiated Win32-input mode
            # can deliver the actual Ctrl+J key without desktop input events.
            ctrl_j = b"\x1b[74;36;10;1;8;1_\x1b[74;36;10;0;8;1_"
            session.edit(ctrl_j + b"local 42]=]", literal)
            session.color(literal, "\n", 32)
            session.color(literal, "local", 32, occurrence=1)
            session.color(literal, "42", 32)
            session.submit()

        with Session(executable, enabled, root, columns=40) as session:
            long_string = 'local text = "' + "x" * 100 + '"'
            session.terminal.send(long_string.encode())
            session.until(lambda: session.trace.x == 38 and session.trace.current_line().startswith(PROMPT + "x") and
                          session.trace.current_line().endswith('"'), "mid-token horizontal viewport missing")
            session.settle()
            assert session.trace.foregrounds[session.trace.y][len(PROMPT)] == 32, "clipped string lost its lexical context"
            session.edit(b"\x01", long_string, len(PROMPT), display=long_string[:32])
            session.color(long_string, "local", 95)
            session.color(long_string, "=", 94)
            session.clear()

        history = root / "ghost.jsonl"
        recalled = "print('ghost-color', 42)"
        history.write_text(json.dumps(recalled) + "\n", encoding="utf-8")
        for highlighting in (True, False):
            options = configuration(root, "ghost-" + str(highlighting), prompt=PROMPT,
                                    history_file=history, autosuggestions=True, syntax_highlighting=highlighting)
            with Session(executable, options, root) as session:
                session.edit("print(", recalled, len(PROMPT) + 6)
                session.color(recalled, "print", 36 if highlighting else None)
                session.color(recalled, "(", 94 if highlighting else None)
                session.color(recalled, "ghost-color", 90, dim=True)
                session.edit(b"\x1b[C", recalled)
                session.color(recalled, "ghost-color", 32 if highlighting else None)
                session.color(recalled, "42", 33 if highlighting else None)
                assert not session.trace.has_dim_text(), "accepted ghost did not become ordinary highlighted input"
                session.clear()

        cached = config(root, "cached")
        with cached.open("a", encoding="utf-8") as source:
            source.write("local original = lush.highlight\nhighlight_42_calls = 0\n"
                         "lush.highlight = function(source) if source == '42' then "
                         "highlight_42_calls = highlight_42_calls + 1 end; return original(source) end\n")
        with Session(executable, cached, root) as session:
            session.edit("42", "42")
            session.edit(b"\x1b[D", "42", len(PROMPT) + 1)
            session.edit(b"\x1b[C", "42")
            session.edit(b"\x01", "42", len(PROMPT))
            session.edit(b"\x05", "42")
            session.terminal.send(b"\x0c")
            session.settle()
            session.submit()
            output = session.submit("assert(highlight_42_calls == 1); print('cache-ok')")
            plain = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", output)
            assert b"\r\ncache-ok\r\n" in plain, plain

        for name, body in (("ansi", "return '\\27[31m'"), ("type", "return {}"),
                           ("error", "error('deliberate highlighter failure')")):
            fallback = config(root, "fallback-" + name)
            with fallback.open("a", encoding="utf-8") as source:
                source.write("lush.highlight = function(source) " + body + " end\n")
            with Session(executable, fallback, root) as session:
                session.edit("42", "42")
                session.color("42", "42", None)
                session.clear()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    args = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows prompt highlighting transcript")
        return
    check(args.exe.resolve(strict=True))
    print("Highlighting checks passed: palette, edits, Unicode, clipping, multiline context, history/ghosts, settings and fallback")


if __name__ == "__main__":
    main()
