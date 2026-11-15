#!/usr/bin/env python3
"""Exercise persistent history and fish-style suggestions in isolated ConPTY sessions."""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import tempfile
import time
import unicodedata

from repl_cursor import PromptTranscript
from tui_cursor import Pseudoconsole


PROMPT = "history> "


def width(text):
    return sum(1 if character == "\n" else 0 if unicodedata.combining(character) else
               2 if unicodedata.east_asian_width(character) in ("W", "F") else 1
               for character in text)


class HistoryTranscript(PromptTranscript):
    def __init__(self):
        super().__init__(120, 80)
        self.dim = False
        self.dim_cells = [[False] * self.columns for _ in range(self.rows)]

    def painted(self, value):
        super().painted(value)
        if not value.startswith("CSI ") and 0 <= self.y < self.rows and 0 <= self.x < self.columns:
            self.dim_cells[self.y][self.x] = self.dim
            if width(value) == 2 and self.x + 1 < self.columns:
                self.cells[self.y][self.x + 1] = ""
                self.dim_cells[self.y][self.x + 1] = self.dim

    def control(self, final):
        if final == "m":
            values = [int(value or 0) for value in self.sequence.split(";")]
            at = 0
            while at < len(values):
                value = values[at]
                if value in (0, 22): self.dim = False
                elif value == 2: self.dim = True
                elif value in (38, 48) and at + 1 < len(values):
                    at += 2 if values[at + 1] == 5 else 4
                at += 1
        super().control(final)

    def has_dim_text(self, first=0, last=None):
        last = self.columns if last is None else last
        return any(self.dim_cells[self.y][column] and self.cells[self.y][column].strip()
                   for column in range(first, last))


class Session:
    def __init__(self, executable, config, history_file, directory):
        self.terminal = Pseudoconsole(executable, None, 120, 80, config_path=config,
                                     history_file=history_file, cwd=directory)
        self.trace = HistoryTranscript()
        self.closed = False
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
            assert self.terminal.poll() is None, (self.terminal.poll(), bytes(self.trace.raw[-1200:]))
        raise AssertionError((description, self.trace.current_line(), self.trace.x,
                              bytes(self.trace.raw[-1600:])))

    def settle(self):
        empty, deadline = 0, time.monotonic() + 3
        while empty < 2 and time.monotonic() < deadline:
            empty = 0 if self.receive() else empty + 1
        assert empty == 2

    def ready(self, after=None):
        self.until(lambda: self.trace.visible and self.trace.current_line() == PROMPT.rstrip() and
                   self.trace.x == len(PROMPT) and (after is None or len(self.trace.raw) > after),
                   "main prompt missing")
        self.settle()

    def edit(self, data, text, caret=None):
        before = len(self.trace.raw)
        self.terminal.send(data.encode("utf-8") if isinstance(data, str) else data)
        expected = PROMPT + text.replace("\n", "↵")
        caret = len(PROMPT) + width(text) if caret is None else caret
        self.until(lambda: len(self.trace.raw) > before and self.trace.visible and
                   self.trace.current_line() == expected.rstrip() and self.trace.x == caret,
                   "edit or suggested text missing")
        self.settle()

    def unchanged(self, data):
        self.settle()
        before = len(self.trace.raw)
        self.terminal.send(data)
        deadline = time.monotonic() + .15
        while time.monotonic() < deadline: self.receive(.025)
        assert len(self.trace.raw) == before, bytes(self.trace.raw[before:])

    def submit(self, source):
        before, row = len(self.trace.raw), self.trace.y
        self.terminal.send(source.encode("utf-8") + b"\r")
        self.until(lambda: len(self.trace.raw) > before and self.trace.y != row and
                   self.trace.current_line() == PROMPT.rstrip() and self.trace.x == len(PROMPT),
                   "submission did not return to the main prompt")
        self.settle()

    def multiline(self, source):
        pieces = source.split("\n")
        for index, line in enumerate(pieces):
            before, row = len(self.trace.raw), self.trace.y
            if index > 0 and line.startswith("print"):
                # This prefix matches earlier saved commands, but a Lua
                # continuation must not suggest an unrelated complete chunk.
                self.terminal.send(b"print")
                self.until(lambda: self.trace.current_line() == "... print" and self.trace.x == 9,
                           "continuation prefix unexpectedly acquired a suggestion")
                self.settle()
                assert not self.trace.has_dim_text(), "continuation input displayed ghost text"
                self.terminal.send(line[5:].encode("utf-8") + b"\r")
            else:
                self.terminal.send(line.encode("utf-8") + b"\r")
            if index + 1 == len(pieces):
                self.ready(after=before)
            else:
                self.until(lambda: len(self.trace.raw) > before and self.trace.y != row and
                           self.trace.current_line() == "..." and self.trace.x == 4,
                           "continuation prompt missing")
                self.settle()
                assert not self.trace.has_dim_text(), "continuation prompt suggested a complete command"

    def clear(self):
        before = len(self.trace.raw)
        self.terminal.send(b"\x05\x15")  # End, then erase the current single-line draft.
        self.ready(after=before)

    def close(self):
        if not self.closed:
            self.terminal.send(b"\x04")
            self.until(lambda: self.terminal.poll() is not None, "empty Ctrl+D did not end the session")
            assert self.terminal.poll() == 0
            self.closed = True
            self.terminal.close()

    def __enter__(self): return self

    def __exit__(self, kind, value, traceback):
        if kind is None: self.close()
        else: self.terminal.close()


def configuration(directory, name, **values):
    path = directory / (name + ".lua")
    settings = {"prompt": PROMPT, "autosuggestions": True, **values}
    path.write_text("\n".join("lush.config." + key + " = " +
                              ("false" if value is False else "true" if value is True else
                               json.dumps(str(value), ensure_ascii=False) if isinstance(value, Path) else
                               json.dumps(value, ensure_ascii=False)) for key, value in settings.items()) + "\n",
                    encoding="utf-8")
    return path


def records(path):
    return [json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line]


def check(executable):
    with tempfile.TemporaryDirectory(prefix="lush-history-") as temporary:
        root = Path(temporary)
        config = configuration(root, "enabled")
        history = root / "saved" / "history.jsonl"
        # Loading an empty session is read-only; no file or directory appears.
        with Session(executable, config, history, root) as session:
            assert not history.exists()
            assert not session.trace.has_dim_text()
        assert not history.exists()

        first = "print('stored-first-marker')"
        second = "print('stored-second-marker')"
        compound = "print('entered-typed'); print('ghost-must-not-run')"
        unicode_command = "print('한글 history')"
        multiline = "for i=1,2 do\nprint('multi-'..i)\nend"
        with Session(executable, config, history, root) as session:
            for command in (first, compound, second, unicode_command): session.submit(command)
            session.multiline(multiline)
        saved = records(history)
        for command in (first, compound, second, unicode_command, multiline): assert command in saved
        assert "for i=1,2 do" not in saved, "incomplete submissions were persisted separately"

        with Session(executable, config, history, root) as session:
            session.edit(b"\x1b[A", multiline)
            session.edit(b"\x1b[A", unicode_command)
            session.edit(b"\x1b[B", multiline)
            session.edit(b"\x1b[B", "")
            assert not session.trace.has_dim_text(), "an empty draft showed a suggestion"
            prefix = "print('stored-"
            caret = len(PROMPT) + len(prefix)
            session.edit(prefix, second, caret)
            assert session.trace.has_dim_text(caret, len(PROMPT) + len(second)), "ghost suffix was not dim"
            assert not session.trace.has_dim_text(0, caret), "typed input was styled as ghost text"
            row = session.trace.y
            session.edit(b"\x1b[C", second)
            assert session.trace.y == row, "Right executed the accepted command"
            assert not session.trace.has_dim_text(), "accepted text remained a ghost"
            before = len(session.trace.raw)
            session.terminal.send(b"\r")
            session.ready(after=before)
            output = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", session.trace.raw[before:])
            assert b"\r\nstored-second-marker\r\n" in output, output

            typed = "print('entered-typed')"
            session.edit(typed, compound, len(PROMPT) + len(typed))
            before = len(session.trace.raw)
            session.terminal.send(b"\r")
            session.ready(after=before)
            output = re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", session.trace.raw[before:])
            assert b"\r\nentered-typed\r\n" in output
            assert b"\r\nghost-must-not-run\r\n" not in output, "Enter executed the ghost suffix"

            session.edit(prefix, second, caret)
            session.edit(b"\x1b[D", prefix, caret - 1)
            assert not session.trace.has_dim_text(), "midline editing retained a suggestion"
            session.edit(b"\x1b[C", second, caret)
            assert session.trace.x == caret, "midline Right accepted the whole suggestion"
            session.edit("Z", prefix + "Z")
            assert not session.trace.has_dim_text(), "a nonmatching edit retained its ghost"
            session.clear()
            session.edit("Print", "Print")
            assert not session.trace.has_dim_text(), "history prefix matching ignored case"
            session.clear()
            session.edit(prefix, second, caret)
            before = len(session.trace.raw)
            session.terminal.send(b"\x0c")
            session.until(lambda: len(session.trace.raw) > before and session.trace.y == 0 and
                          session.trace.x == caret and session.trace.current_line() == PROMPT + second,
                          "Ctrl+L lost the draft or suggestion")
            session.settle()
            assert session.trace.has_dim_text(caret), "Ctrl+L turned the ghost into normal input"
            session.clear()
            session.edit("to.", "to.")
            before = len(session.trace.raw)
            session.terminal.send(b"\t")
            session.until(lambda: b"json" in session.trace.raw[before:] and b"text" in session.trace.raw[before:] and
                          session.trace.current_line() == PROMPT + "to." and session.trace.x == len(PROMPT) + 3,
                          "completion failed while autosuggestions were enabled")
            session.settle()
            session.clear()

        disabled_store = root / "disabled.jsonl"
        disabled_store.write_text(json.dumps(first) + "\n", encoding="utf-8")
        before = disabled_store.read_bytes()
        disabled = configuration(root, "disabled", history_file=False)
        with Session(executable, disabled, disabled_store, root) as session:
            session.unchanged(b"\x1b[A")
            session.submit("print('in-memory-only')")
            session.edit(b"\x1b[A", "print('in-memory-only')")
            session.edit(b"\x1b[B", "")
        assert disabled_store.read_bytes() == before

        chosen, ignored = root / "chosen.jsonl", root / "ignored.jsonl"
        override = configuration(root, "override", history_file=chosen)
        with Session(executable, override, ignored, root) as session: session.submit(first)
        assert first in records(chosen) and not ignored.exists(), "Lua history path did not override the environment"

        limited_store = root / "limited.jsonl"
        limited_store.write_text("".join(json.dumps(value) + "\n" for value in (first, second, compound)), encoding="utf-8")
        limited = configuration(root, "limited", history_limit=2)
        with Session(executable, limited, limited_store, root) as session:
            session.edit(b"\x1b[A", compound)
            session.edit(b"\x1b[A", second)
            session.unchanged(b"\x1b[A")
            session.edit(b"\x1b[B", compound)
            session.edit(b"\x1b[B", "")

        zero_store = root / "zero-limit.jsonl"
        zero_store.write_text(json.dumps(first) + "\n", encoding="utf-8")
        before = zero_store.read_bytes()
        zero = configuration(root, "zero-limit", history_limit=0)
        with Session(executable, zero, zero_store, root) as session:
            session.unchanged(b"\x1b[A")
            session.submit(second)
            session.unchanged(b"\x1b[A")
        assert zero_store.read_bytes() == before, "limit zero wrote command history"

        no_ghost_store = root / "no-suggestions.jsonl"
        no_ghost_store.write_text(json.dumps(first) + "\n", encoding="utf-8")
        no_ghost = configuration(root, "no-suggestions", autosuggestions=False)
        with Session(executable, no_ghost, no_ghost_store, root) as session:
            session.edit(prefix, prefix)
            assert not session.trace.has_dim_text()
            session.clear()
            session.edit(b"\x1b[A", first)
            session.edit(b"\x1b[B", "")
            session.submit(second)
        assert second in records(no_ghost_store), "disabling suggestions disabled persistence"

        imported_controls = root / "imported-controls.jsonl"
        imported_controls.write_text("".join(json.dumps(value) + "\n" for value in (
            "print\t('tab-record')", "print\r('carriage-record')", "print\x1b('escape-record')",
        )), encoding="utf-8")
        with Session(executable, config, imported_controls, root) as session:
            session.edit("print", "print")
            assert not session.trace.has_dim_text(), "an imported control-bearing command became a ghost"
            session.unchanged(b"\x1b[C")
            session.clear()

        changed_directory = root / "configuration changed cwd"
        changed_directory.mkdir()
        relative = configuration(root, "relative", history_file="relative-history.jsonl")
        with relative.open("a", encoding="utf-8") as source:
            source.write("cd(" + json.dumps(str(changed_directory)) + ")\n")
        ignored_relative = root / "ignored-relative.jsonl"
        with Session(executable, relative, ignored_relative, root) as session: session.submit(first)
        assert first in records(root / "relative-history.jsonl")
        assert not (changed_directory / "relative-history.jsonl").exists() and not ignored_relative.exists()

        for name, setting, value in (("invalid-limit", "history_limit", -1),
                                     ("drive-relative", "history_file", "D:history.jsonl")):
            invalid = configuration(root, name, **{setting: value})
            invalid_store = root / (name + ".jsonl")
            terminal = Pseudoconsole(executable, None, 120, 80, config_path=invalid,
                                     history_file=invalid_store, cwd=root)
            output, deadline = bytearray(), time.monotonic() + 8
            try:
                while terminal.poll() is None and time.monotonic() < deadline:
                    output.extend(terminal.receive())
                output.extend(terminal.receive())
                assert terminal.poll() not in (None, 0), "invalid history setting started a shell"
                assert setting.encode() in output, output
                assert not invalid_store.exists()
            finally:
                terminal.close()

        exit_store = root / "os-exit.jsonl"
        session = Session(executable, config, exit_store, root)
        try:
            session.terminal.send(b"os.exit(0)\r")
            session.until(lambda: session.terminal.poll() is not None, "os.exit did not terminate")
            assert session.terminal.poll() == 0
            assert "os.exit(0)" in records(exit_store), "os.exit bypassed saving its command"
        finally:
            session.terminal.close()

        concurrent_store = root / "concurrent.jsonl"
        left = Session(executable, config, concurrent_store, root)
        right = Session(executable, config, concurrent_store, root)
        try:
            a, b = "print('concurrent-a')", "print('concurrent-b')"
            left_before, right_before = len(left.trace.raw), len(right.trace.raw)
            left.terminal.send(a.encode() + b"\r")
            right.terminal.send(b.encode() + b"\r")
            left.ready(after=left_before)
            right.ready(after=right_before)
            left.close()
            right.close()
            assert a in records(concurrent_store) and b in records(concurrent_store), "simultaneous sessions lost an append"
        finally:
            left.terminal.close()
            right.terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    args = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows interactive history test")
        return
    check(args.exe.resolve(strict=True))
    print("History checks passed: persistence, Unicode/multiline recall, dim suggestions, Right/Enter, configuration and concurrent append")


if __name__ == "__main__":
    main()
