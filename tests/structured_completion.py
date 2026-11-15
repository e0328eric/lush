#!/usr/bin/env python3
"""Discover structured builtin outputs without evaluating unfinished Lua code."""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from history import HistoryTranscript, width
from record_completion import plain
from tui_cursor import Pseudoconsole


PROMPT = "records> "

GUARD = r'''
structured_completion_calls = 0
local function forbidden()
    structured_completion_calls = structured_completion_calls + 1
    error('structured discovery evaluated a producer')
end
_lush.stat, _lush.execute, _lush.list, _lush.fls_records, _lush.executables =
    forbidden, forbidden, forbidden, forbidden, forbidden
'''


def check_help(executable):
    source = GUARD + r'''
local topics = {
    {stat, 'size', 'integer'},
    {version, 'platform', 'string'},
    {capture, 'stdout', 'string'},
    {commands, 'name', 'string'},
    {enumerate, 'index', 'integer'},
    {lush.theme.prompt, 'rows', 'array'},
}
for _, topic in ipairs(topics) do
    local text = help(topic[1])
    assert(type(text) == 'string' and text:find('Output fields:', 1, true), text)
    assert(text:find(topic[2] .. ' (', 1, true), text)
    assert(text:match(topic[2] .. ' %([^%)]*' .. topic[3]), text)
end
local result_help = help(capture)
assert(result_help:find('statuses[]', 1, true), result_help)
assert(help(lush.theme.prompt):find('rows[].', 1, true), 'nested prompt fields are missing')
assert(structured_completion_calls == 0)
print('structured-help-ok')
'''
    result = subprocess.run([str(executable), "--no-config", "-c", source], capture_output=True,
                            text=True, encoding="utf-8", timeout=10)
    assert result.returncode == 0, (result.stdout, result.stderr)
    assert result.stdout == "structured-help-ok\n", (result.stdout, result.stderr)


def check_terminal(executable):
    with tempfile.TemporaryDirectory(prefix="lush-structured-completion-") as temporary:
        root = Path(temporary)
        configuration = root / "init.lua"
        configuration.write_text("lush.config.prompt = 'records> '\n"
                                 "lush.config.history_file = false\n"
                                 "lush.config.autosuggestions = false\n" + GUARD, encoding="utf-8")
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

        def edit(data, source):
            before = len(trace.raw)
            terminal.send(data.encode("utf-8") if isinstance(data, str) else data)
            until(lambda: len(trace.raw) > before and trace.visible and
                  trace.x == len(PROMPT) + width(source) and trace.current_line() == PROMPT + source,
                  "structured completion or caret missing")
            settle()

        def cancel():
            terminal.send(b"\x03")
            ready()

        def complete(source, expected):
            edit(source, source)
            edit(b"\t", expected)
            cancel()

        try:
            ready()
            complete("stat('missing-do-not-touch').si", "stat('missing-do-not-touch').size")
            complete("local info=version(); info.pl", "local info=version(); info.platform")
            complete("commands():where(function(c) return c.na", "commands():where(function(c) return c.name")

            # These properties share a prefix, so Tab must list their types and
            # leave the unsubmitted capture() and its command completely idle.
            source = "local result=capture(cmd.nonexistent()); result.st"
            edit(source, source)
            before = len(trace.raw)
            terminal.send(b"\t")
            until(lambda: "stdout" in plain(trace.raw[before:]) and "statuses" in plain(trace.raw[before:]) and
                  trace.visible and trace.current_line() == PROMPT + source and
                  trace.x == len(PROMPT) + width(source), "Result fields were not listed")
            settle()
            labels = plain(trace.raw[before:])
            assert re.search(r"\bstdout\s*[:(]\s*string\b", labels), labels
            assert re.search(r"\bstatuses\s*[:(]\s*(?:array|list|integer\[)", labels), labels
            cancel()

            complete("ls():enumerate():where(function(row) return row.item.si",
                     "ls():enumerate():where(function(row) return row.item.size")

            before = len(trace.raw)
            terminal.send(b"assert(structured_completion_calls == 0); print('structured-metadata-only-ok')\r")
            until(lambda: "\r\nstructured-metadata-only-ok\r\n" in plain(trace.raw[before:]) and
                  trace.current_line() == PROMPT.rstrip() and trace.x == len(PROMPT),
                  "structured completion evaluated a producer")
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
        print("SKIP: Windows structured-output completion transcript")
        return
    executable = arguments.exe.resolve(strict=True)
    check_help(executable)
    check_terminal(executable)
    print("Structured completion checks passed: direct records, locals, command rows, nested items, typed help and zero producer calls")


if __name__ == "__main__":
    main()
