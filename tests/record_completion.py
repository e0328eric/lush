#!/usr/bin/env python3
"""Exercise discoverable ls record fields without evaluating an unfinished callback."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from history import HistoryTranscript, width
from tui_cursor import Pseudoconsole


PROMPT = "fields> "


def plain(data):
    return re.sub(rb"\x1b\[[0-?]*[ -/]*[@-~]", b"", data).decode("utf-8", "replace")


def check_help(executable):
    source = r'''
local calls = 0
local function forbidden() calls = calls + 1; error('help evaluated a filesystem source') end
_lush.list, _lush.fls_records, _lush.executables = forbidden, forbidden, forbidden
local text = help(ls)
assert(text == help('ls') and calls == 0)
io.write(text)
'''
    result = subprocess.run([str(executable), "--no-config", "-c", source], capture_output=True,
                            text=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert "Output fields:" in result.stdout
    assert re.search(r"\bsize\s*\(integer\)", result.stdout), result.stdout
    assert re.search(r"\btype\s*\(string\)", result.stdout), result.stdout


def check(executable):
    check_help(executable)
    with tempfile.TemporaryDirectory(prefix="lush-record-completion-") as temporary:
        root = Path(temporary)
        configuration = root / "init.lua"
        configuration.write_text(r'''
lush.config.prompt = 'fields> '
lush.config.history_file = false
lush.config.autosuggestions = false
record_completion_calls = 0
local function forbidden()
    record_completion_calls = record_completion_calls + 1
    error('completion evaluated a filesystem source')
end
_lush.list, _lush.fls_records, _lush.executables = forbidden, forbidden, forbidden
''', encoding="utf-8")
        terminal = Pseudoconsole(executable, None, 120, 80, config_path=configuration,
                                 history_file=root / "unused-history.jsonl", cwd=root,
                                 environment={"TERM": "xterm-256color", "NO_COLOR": ""})
        trace = HistoryTranscript()

        def receive(timeout=.04):
            data = terminal.receive(timeout)
            trace.feed(data)
            return data

        def until(predicate, description):
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                receive()
                if predicate(): return
                assert terminal.poll() is None, (terminal.poll(), bytes(trace.raw[-1200:]))
            raise AssertionError((description, trace.current_line(), trace.x, bytes(trace.raw[-1800:])))

        def settle():
            empty, deadline = 0, time.monotonic() + 3
            while empty < 2 and time.monotonic() < deadline:
                empty = 0 if receive() else empty + 1
            assert empty == 2

        def ready():
            until(lambda: trace.visible and trace.current_line() == PROMPT.rstrip() and trace.x == len(PROMPT),
                  "empty prompt missing")
            settle()

        def edit(data, source, caret=None, prompt=PROMPT):
            before = len(trace.raw)
            terminal.send(data.encode("utf-8") if isinstance(data, str) else data)
            caret = len(prompt) + width(source) if caret is None else caret
            until(lambda: len(trace.raw) > before and trace.visible and trace.x == caret and
                  trace.current_line() == prompt + source, "record callback edit missing")
            settle()

        def cancel():
            terminal.send(b"\x03")
            ready()

        try:
            ready()
            source = "ls():where(function(f) return f."
            edit(source, source)
            before = len(trace.raw)
            terminal.send(b"\t")
            until(lambda: "integer" in plain(trace.raw[before:]) and "string" in plain(trace.raw[before:]) and
                  trace.visible and trace.current_line() == PROMPT + source and
                  trace.x == len(PROMPT) + width(source), "record fields and types were not listed")
            settle()
            labels = plain(trace.raw[before:])
            for field, kind in (("size", "integer"), ("type", "string"), ("name", "string")):
                assert re.search(r"\b" + field + r"(?:\s+|\s*[:(]\s*)" + kind + r"\b", labels), labels
            cancel()

            source = "ls():where(function(f) return f.si"
            edit(source, source)
            completed = source[:-2] + "size"
            edit(b"\t", completed)
            before = len(trace.raw)
            terminal.send(b"\x0c")
            until(lambda: len(trace.raw) > before and trace.visible and trace.y == 0 and
                  trace.x == len(PROMPT) + width(completed) and trace.current_line() == PROMPT + completed,
                  "Ctrl+L lost the completed field or caret")
            settle()
            cancel()

            source = "ls():where(function(entry) return entry.Size"
            edit(source, source)
            before = len(trace.raw)
            terminal.send(b"\t")
            deadline = time.monotonic() + .2
            while time.monotonic() < deadline: receive(.025)
            assert len(trace.raw) == before and trace.current_line() == PROMPT + source, \
                "record field names were matched without regard to case"
            cancel()

            # The replacement offset is a UTF-8 byte offset; the caret remains
            # measured in display cells and the closing Lua suffix is retained.
            source = 'local label = "한글"; ls():where(function(entry) return entry.si end)'
            suffix = " end)"
            edit(source, source)
            edit(b"\x1b[D" * len(suffix), source, len(PROMPT) + width(source[:-len(suffix)]))
            completed = source[:-len(suffix) - 2] + "size" + suffix
            edit(b"\t", completed, len(PROMPT) + width(completed[:-len(suffix)]))
            cancel()

            # Infer the callback binding from the unexecuted preceding line.
            source = "ls():where(function(entry)"
            edit(source, source)
            terminal.send(b"\r")
            until(lambda: trace.visible and trace.current_line() == "..." and trace.x == 4,
                  "callback continuation prompt missing")
            settle()
            edit("return entry.si", "return entry.si", prompt="... ")
            edit(b"\t", "return entry.size", prompt="... ")
            cancel()

            before = len(trace.raw)
            terminal.send(b"assert(record_completion_calls == 0); print('metadata-only-ok')\r")
            until(lambda: "\r\nmetadata-only-ok\r\n" in plain(trace.raw[before:]) and
                  trace.current_line() == PROMPT.rstrip() and trace.x == len(PROMPT),
                  "field completion evaluated the directory source")
            settle()
            terminal.send(b"exit(0)\r")
            until(lambda: terminal.poll() is not None, "shell did not exit")
            assert terminal.poll() == 0
        finally:
            terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    arguments = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows record-field completion transcript")
        return
    check(arguments.exe.resolve(strict=True))
    print("Record completion checks passed: typed fields, multiline scope, Unicode caret, Ctrl+L and metadata-only discovery")


if __name__ == "__main__":
    main()
