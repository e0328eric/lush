#!/usr/bin/env python3
"""Exercise colored prompt themes in isolated, invisible Windows pseudoconsoles."""

from __future__ import annotations

import argparse
import ctypes as ct
from ctypes import wintypes as wt
import json
import os
from pathlib import Path
import re
import tempfile
import time

from highlighting import Colors
from history import width
from tui_cursor import Pseudoconsole

ROOT = Path(__file__).resolve().parents[1]

class ThemeTranscript(Colors):
    def __init__(self, columns, rows):
        super().__init__(columns, rows)
        self.background = None
        self.backgrounds = [[None] * columns for _ in range(rows)]

    def painted(self, value):
        super().painted(value)
        if not value.startswith("CSI ") and 0 <= self.y < self.rows and 0 <= self.x < self.columns:
            self.backgrounds[self.y][self.x] = self.background

    def control(self, final):
        sequence = self.sequence
        if final in "EF":
            count = int(sequence or 1)
            self.x = 0
            self.y = max(0, min(self.rows - 1, self.y + (count if final == "E" else -count)))
        if final == "m":
            values, at = [int(value or 0) for value in sequence.split(";")], 0
            while at < len(values):
                value = values[at]
                if value in (0, 49): self.background = None
                elif 40 <= value <= 47 or 100 <= value <= 107: self.background = value
                elif value in (38, 48) and at + 1 < len(values):
                    count = 2 if values[at + 1] == 5 else 4
                    if value == 48 and at + count < len(values):
                        self.background = ("indexed", values[at + 2]) if count == 2 else ("rgb", *values[at + 2:at + 5])
                    at += count
                at += 1
        super().control(final)

    def line(self, row):
        return "".join(self.cells[row]).rstrip()

    def token_column(self, row, token):
        for column in range(self.columns - len(token) + 1):
            if "".join(self.cells[row][column:column + len(token)]) == token:
                return column
        raise AssertionError(("token missing", token, self.line(row)))


class Session:
    def __init__(self, executable, configuration, directory, prefix, headers, columns=120):
        self.terminal = Pseudoconsole(executable, None, columns, 60, config_path=configuration,
                                     history_file=directory / "isolated-history.jsonl", cwd=directory,
                                     environment={"TERM": "xterm-256color", "NO_COLOR": ""})
        self.trace = ThemeTranscript(columns, 60)
        self.prefix, self.headers = prefix, headers
        self.until(lambda: self.trace.visible and self.trace.x == width(prefix) and
                   self.trace.y == headers and self.trace.current_line() == prefix.rstrip(), "initial themed prompt missing")
        self.settle()
        self.trace.monitor = True

    def receive(self, timeout=.04):
        data = self.terminal.receive(timeout)
        self.trace.feed(data)
        if self.trace.monitor: self.trace.assert_atomic()
        return data

    def until(self, predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            self.receive()
            if predicate(): return
            assert self.terminal.poll() is None, (self.terminal.poll(), bytes(self.trace.raw[-1000:]))
        raise AssertionError((description, self.trace.current_line(), self.trace.x, self.trace.y,
                              bytes(self.trace.raw[-1800:])))

    def settle(self):
        empty, deadline = 0, time.monotonic() + 3
        while empty < 2 and time.monotonic() < deadline:
            empty = 0 if self.receive() else empty + 1
        assert empty == 2

    def edit(self, data, displayed, caret=None):
        before = len(self.trace.raw)
        self.terminal.send(data.encode("utf-8") if isinstance(data, str) else data)
        caret = width(self.prefix + displayed) if caret is None else caret
        self.until(lambda: len(self.trace.raw) > before and self.trace.visible and self.trace.x == caret and
                   self.trace.current_line() == (self.prefix + displayed).rstrip(), "themed edit missing")
        self.settle()

    def unchanged(self, data):
        self.settle()
        before = len(self.trace.raw)
        self.terminal.send(data)
        deadline = time.monotonic() + .2
        while time.monotonic() < deadline: self.receive(.025)
        assert len(self.trace.raw) == before, ("unchanged key repainted a theme", bytes(self.trace.raw[before:]))

    def clear_input(self):
        self.edit(b"\x05\x15", "")

    def clear_screen(self, displayed, caret=None):
        self.trace.monitor = False
        self.edit(b"\x0c", displayed, caret)
        assert self.trace.y == self.headers, "Ctrl+L lost the header/input layout"
        self.trace.monitor = True

    def resize(self, columns):
        # ConPTY resizing affects only this invisible console, never the user's
        # terminal or desktop. Its repaint is intentionally outside key checks.
        self.trace.monitor = False
        coordinate = self.terminal.kernel.CreatePseudoConsole.argtypes[0]
        resize = self.terminal.kernel.ResizePseudoConsole
        resize.argtypes, resize.restype = [wt.HANDLE, coordinate], ct.c_long
        for name, blank in (("cells", " "), ("dim_cells", False), ("foregrounds", None), ("backgrounds", None)):
            values = getattr(self.trace, name)
            for row in range(self.trace.rows):
                values[row] = values[row][:columns] + [blank] * max(0, columns - len(values[row]))
        self.trace.columns = columns
        self.trace.x = min(self.trace.x, columns - 1)
        status = resize(self.terminal.console, coordinate(columns, self.trace.rows))
        assert status >= 0, ("ResizePseudoConsole", status)

    def close(self):
        self.terminal.send(b"\x04")
        self.until(lambda: self.terminal.poll() is not None, "empty Ctrl+D did not exit")
        assert self.terminal.poll() == 0
        self.terminal.close()

    def __enter__(self): return self

    def __exit__(self, kind, value, traceback):
        if kind is None: self.close()
        else: self.terminal.close()


def configuration(root, name, body):
    path = root / (name + ".lua")
    path.write_text("lush.config.history_file = false\nlush.config.autosuggestions = false\n" + body + "\n", encoding="utf-8")
    return path


def check(executable):
    with tempfile.TemporaryDirectory(prefix="lush-themes-") as temporary:
        root = Path(temporary)
        # Merely selecting an example's name must not find a hidden compiled
        # preset when neither the config registry nor a theme file provides it.
        unloaded = configuration(root, "unloaded-name", "lush.config.theme='powerlevel10k_classic'")
        terminal = Pseudoconsole(executable, None, 120, 60, config_path=unloaded,
                                 history_file=root / "unloaded-history.jsonl", cwd=root,
                                 environment={"TERM": "xterm-256color", "NO_COLOR": ""})
        trace, deadline = ThemeTranscript(120, 60), time.monotonic() + 8
        try:
            while time.monotonic() < deadline:
                trace.feed(terminal.receive())
                if terminal.poll() is not None or (trace.visible and trace.current_line() == "lush>"):
                    break
            assert b"unknown prompt theme" in trace.raw, bytes(trace.raw[-1600:])
            assert terminal.poll() is not None or trace.current_line() == "lush>", \
                "an unregistered name unexpectedly selected an example composition"
            if terminal.poll() is None:
                terminal.send(b"exit(0)\r")
                deadline = time.monotonic() + 8
                while terminal.poll() is None and time.monotonic() < deadline:
                    trace.feed(terminal.receive())
                assert terminal.poll() == 0
        finally:
            terminal.close()
        for name, prefix in (("powerlevel10k_classic", "> "), ("easy-term", "`- "), ("iterm2", "> ")):
            external = ROOT / "themes" / (name + ".lua")
            if name == "powerlevel10k_classic":
                selection = "lush.config.themes = {[" + json.dumps(name) + "]=source(" + json.dumps(str(external)) + ")}\n" + \
                            "lush.config.theme=" + json.dumps(name)
            elif name == "easy-term":
                # Exercise the selected-file loader through the actual REPL;
                # repeated editing/clearing must reuse its loaded descriptor.
                selected_directory = root / "themes"
                selected_directory.mkdir(exist_ok=True)
                (selected_directory / external.name).write_bytes(
                    b'assert(not _G.__selected_theme_loaded, "theme file executed twice")\n'
                    b'_G.__selected_theme_loaded = true\n' + external.read_bytes())
                (selected_directory / "unselected.lua").write_text(
                    'error("unselected theme executed")\n', encoding="utf-8")
                selection = "lush.config.theme=" + json.dumps(name)
            else:
                selection = "lush.config.theme=source(" + json.dumps(str(external)) + ")"
            options = configuration(root, name, selection +
                                    "\nlush.config.theme_options = {icons=false, git=false, root=false}")
            with Session(executable, options, root, prefix, 1) as session:
                header = session.trace.line(0)
                assert header, (name, "empty theme header")
                assert re.search(r"\b\d{2}:\d{2}(?::\d{2})?\b", header), (name, "right-side clock missing", header)
                assert any(value is not None for value in session.trace.foregrounds[0]) or \
                       any(value is not None for value in session.trace.backgrounds[0]), (name, "theme colors were stripped")
                session.edit("42", "42")
                assert session.trace.foregrounds[session.trace.y][width(prefix)] == 33, "theme input lost Lua syntax colors"
                assert session.trace.line(0) == header, "ordinary editing repainted the theme header"
                session.unchanged(b"\x1b[17~")  # Unbound F6.
                session.edit(b"\x1b[D", "42", width(prefix) + 1)
                session.clear_screen("42", width(prefix) + 1)
                assert session.trace.line(0) == header
                session.clear_input()

        # Editing a copied configuration changes the prompt without rebuilding
        # the executable or registering a name in its core utilities.
        edited_file = root / "edited-example.lua"
        original = (ROOT / "themes" / "powerlevel10k_classic.lua").read_text(encoding="utf-8")
        edited_file.write_text("local descriptor = (function()\n" + original +
                               "\nend)()\ndescriptor.input = {lush.theme.text('edited> ')}\nreturn descriptor\n",
                               encoding="utf-8")
        edited = configuration(root, "edited-config", "lush.config.theme=source(" + json.dumps(str(edited_file)) +
                               ")\nlush.config.theme_options={icons=false,git=false,root=false}")
        with Session(executable, edited, root, "edited> ", 1) as session:
            session.edit("42", "42")
            session.clear_input()

        direct = configuration(root, "direct", r'''
lush.config.prompt = function()
    return {lines={
        {left='\27[31mLEFT한글\27[0m\27[2J\27]0;BAD-THEME-TITLE\7 KEEP', right='\27[32mRIGHT\27[0m'},
        {left='SECOND', right='END'}
    }, input='\27[36mcustom> \27[0m\27[999C\7'}
end
''')
        with Session(executable, direct, root, "custom> ", 2) as session:
            assert session.trace.line(0).startswith("LEFT한글 KEEP")
            assert session.trace.foregrounds[0][0] == 31, "allowed SGR was removed from the left prompt"
            assert session.trace.token_column(0, "RIGHT") == 120 - 1 - len("RIGHT")
            assert session.trace.foregrounds[0][120 - 1 - len("RIGHT")] == 32
            assert session.trace.token_column(1, "END") == 120 - 1 - len("END")
            assert (b"BAD-THEME-TITLE" not in session.trace.raw and b"\x1b[999C" not in session.trace.raw), \
                "unsafe prompt cursor/title controls escaped sanitization"
            session.edit('print("한글")', 'print("한글")')
            session.edit(b"\x1b[D" * 3, 'print("한글")', len("custom> ") + 9)
            session.clear_screen('print("한글")', len("custom> ") + 9)
            assert session.trace.line(0).startswith("LEFT한글 KEEP") and session.trace.line(1).startswith("SECOND")
            session.clear_input()
            session.edit("to.", "to.")
            session.trace.monitor = False  # Listing choices is intentional output.
            before = len(session.trace.raw)
            session.terminal.send(b"\t")
            session.until(lambda: b"json" in session.trace.raw[before:] and b"text" in session.trace.raw[before:] and
                          session.trace.visible and session.trace.current_line() == "custom> to." and
                          session.trace.x == len("custom> to.") and session.trace.y >= 2 and
                          session.trace.line(session.trace.y - 2).startswith("LEFT한글 KEEP") and
                          session.trace.line(session.trace.y - 1).startswith("SECOND"),
                          "Tab choices did not receive a fresh header above the draft")
            session.settle()
            assert any("json" in session.trace.line(row) and "text" in session.trace.line(row)
                       for row in range(session.trace.y - 2)), "theme headers overwrote completion choices"
            # repl_resize.py checks this exact Tab-grid/120-to-80 resize
            # against real console cells. This color transcript does not model
            # the host's reflow of old rows during a full resize repaint.
            session.trace.monitor = True
            session.edit("json", "to.json")
            session.clear_input()

        custom = configuration(root, "builder", r'''
local t = lush.theme
lush.config.themes = {custom=function(context, options)
    return t.prompt{rows={t.row{
        left={t.text('CUSTOM ', {fg='#ff00ff'}), t.path()},
        right={t.text('BUILDER-RIGHT', {fg='#00ff00'})}
    }}, input={t.text('builder> ', {fg='#00ffff'})}}
end}
lush.config.theme = 'custom'
lush.config.theme_options = {icons=false, git=false, root=false}
''')
        with Session(executable, custom, root, "builder> ", 1) as session:
            assert session.trace.line(0).startswith("CUSTOM ")
            assert session.trace.foregrounds[0][0] is not None
            assert session.trace.token_column(0, "BUILDER-RIGHT") == 120 - 1 - len("BUILDER-RIGHT")
            session.edit("1+2", "1+2")
            session.clear_input()

        for name, body, prefix in (
            ("legacy-string", "lush.config.prompt='\\27[35mlegacy> \\27[0m'", "legacy> "),
            ("legacy-function", "lush.config.prompt=function() return 'function> ' end", "function> "),
        ):
            legacy = configuration(root, name, "lush.config.theme='iterm2'\n" + body)
            with Session(executable, legacy, root, prefix, 0) as session:
                if name == "legacy-string": assert session.trace.foregrounds[0][0] == 35
                session.edit("42", "42")
                session.clear_input()

        history = root / "ghost.jsonl"
        candidate = "print('theme-ghost', 42)"
        history.write_text(json.dumps(candidate) + "\n", encoding="utf-8")
        ghost = configuration(root, "ghost", "lush.config.theme=source(" +
                              json.dumps(str(ROOT / "themes" / "powerlevel10k_classic.lua")) + ")\n"
                              "lush.config.theme_options={icons=false,git=false,root=false}\n"
                              "lush.config.autosuggestions=true\nlush.config.history_file=" + json.dumps(str(history)))
        with Session(executable, ghost, root, "> ", 1) as session:
            prefix = "print("
            caret = len("> ") + len(prefix)
            session.edit(prefix, candidate, caret)
            assert session.trace.has_dim_text(caret), "themed prompt lost the dim suggestion"
            assert session.trace.foregrounds[session.trace.y][len("> ")] == 36
            session.edit(b"\x1b[C", candidate)
            string_column = len("> ") + candidate.index("theme-ghost")
            assert session.trace.foregrounds[session.trace.y][string_column] == 32
            assert not session.trace.has_dim_text(), "accepted suggestion remained dim in a theme"
            session.clear_input()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    args = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows prompt theme transcript")
        return
    check(args.exe.resolve(strict=True))
    print("Theme checks passed: presets, colored headers, right alignment, Unicode, editing, Ctrl+L, builders, legacy prompts and ghosts")


if __name__ == "__main__":
    main()
