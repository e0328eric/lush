#!/usr/bin/env python3
"""Check prompt redraws, history and unchanged keys through an invisible ConPTY.

Run: python tests/repl_cursor.py --exe build/lush.exe
"""

from __future__ import annotations

import argparse
import os
from pathlib import Path
import time

from tui_cursor import Pseudoconsole, Transcript


PROMPT = "test> "


class PromptTranscript(Transcript):
    def __init__(self, columns, rows):
        super().__init__(columns, rows)
        self.monitor = False
        self.preclears = []
        self.cells = [[" "] * columns for _ in range(rows)]

    def painted(self, value):
        if self.monitor and self.visible:
            self.paint_while_visible.append((self.x, self.y, value))
        if not value.startswith("CSI ") and 0 <= self.y < self.rows and 0 <= self.x < self.columns:
            self.cells[self.y][self.x] = value

    def control(self, final):
        sequence = self.sequence
        if self.monitor and final == "K" and (sequence == "2" or
                                              (sequence in ("", "0") and self.x == 0)):
            self.preclears.append((self.x, self.y))
        if final == "J" and sequence in ("2", "3"):
            self.cells = [[" "] * self.columns for _ in range(self.rows)]
        if final in "KX" and 0 <= self.y < self.rows:
            value = int(sequence or 0)
            first = 0 if final == "K" and value == 2 else self.x
            last = self.columns if final == "K" else min(self.columns, first + (value or 1))
            for column in range(first, last):
                self.cells[self.y][column] = " "
        super().control(final)
        # The shared TUI parser records reveals only in the alternate buffer.
        # Prompt editing stays in the main buffer.
        if final == "h" and sequence.startswith("?") and "25" in sequence[1:].split(";"):
            if not self.alternate:
                self.shows.append((self.x, self.y))

    def current_line(self):
        return "".join(self.cells[self.y]).rstrip()

    def assert_atomic(self):
        # ConPTY coalesces an application's hide/paint/show sequence into a
        # screen delta and can omit both visibility controls. Observe whether
        # it exposes a destructive blank-line phase, rather than inferring the
        # original application's write ordering from that lossy transcript.
        assert not self.preclears, "prompt destructively cleared its whole line before repainting"


def check(executable):
    terminal = Pseudoconsole(executable, None, 100, 30)
    transcript = PromptTranscript(100, 30)

    def receive(timeout=.05):
        data = terminal.receive(timeout)
        transcript.feed(data)
        if transcript.monitor:
            transcript.assert_atomic()
        return data

    def until(predicate, description):
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            receive()
            if predicate():
                return
            assert terminal.poll() is None, ("REPL exited", terminal.poll(), bytes(transcript.raw[-1000:]))
        raise AssertionError((description, transcript.current_line(), bytes(transcript.raw[-1500:])))

    def settle():
        empty = 0
        deadline = time.monotonic() + 3
        while empty < 2 and time.monotonic() < deadline:
            empty = 0 if receive() else empty + 1
        assert empty == 2, "prompt did not settle"

    def submit(source):
        before, row = len(transcript.raw), transcript.y
        terminal.send(source.encode("utf-8") + b"\r")
        until(lambda: len(transcript.raw) > before and transcript.y != row and transcript.visible and
              transcript.x == len(PROMPT) and transcript.current_line() == PROMPT.rstrip(),
              "submitted command did not return to the prompt")
        settle()

    def edit(data, cursor, line=None, prefix=PROMPT, row=None):
        before = len(transcript.raw)
        terminal.send(data)
        until(lambda: len(transcript.raw) > before and transcript.visible and transcript.x == cursor and
              (row is None or transcript.y == row) and
              (line is None or transcript.current_line() == (prefix + line).rstrip()),
              "prompt did not finish the expected edit")
        settle()

    def unchanged(data):
        settle()
        before = len(transcript.raw)
        terminal.send(data)
        deadline = time.monotonic() + .2
        while time.monotonic() < deadline:
            receive(.025)
        assert len(transcript.raw) == before, (
            "unchanged key repainted the prompt", bytes(transcript.raw[before:]),
        )

    try:
        until(lambda: b" >" in transcript.raw, "initial prompt missing")
        settle()
        submit("lush.config.prompt='test> '")
        longer = "print('history-long-marker-123456789')"
        shorter = "print('x')"
        submit(longer)
        submit(shorter)
        transcript.monitor = True

        edit(b"\x1b[A", len(PROMPT) + len(shorter), shorter)
        edit(b"\x1b[A", len(PROMPT) + len(longer), longer)
        edit(b"\x1b[B", len(PROMPT) + len(shorter), shorter)
        edit(b"\x1b[B", len(PROMPT), "")
        unchanged(b"\x1b[B")  # Newest-history boundary.

        # Reach the oldest history entry, then verify another Up is silent.
        for _ in range(3):
            terminal.send(b"\x1b[A")
            settle()
        unchanged(b"\x1b[A")
        for _ in range(3):
            terminal.send(b"\x1b[B")
            settle()
        assert transcript.current_line() == PROMPT.rstrip()

        edit(b"12+()", len(PROMPT) + 5, "12+()")
        edit(b"\x1b[D", len(PROMPT) + 4, "12+()")
        # Ctrl+L intentionally clears the screen, then must restore both the
        # current edit and its midline caret at the new top row.
        transcript.monitor = False
        before = len(transcript.raw)
        terminal.send(b"\x0c")
        until(lambda: len(transcript.raw) > before and transcript.visible and
              (transcript.x, transcript.y) == (len(PROMPT) + 4, 0) and
              transcript.current_line() == PROMPT + "12+()", "Ctrl+L lost the edit or caret")
        settle()
        transcript.monitor = True
        edit(b"3", len(PROMPT) + 5, "12+(3)")

        # Explicit cancellation is output, not a redraw; begin a fresh draft.
        transcript.monitor = False
        terminal.send(b"\x03")
        until(lambda: transcript.current_line() == PROMPT.rstrip() and transcript.x == len(PROMPT),
              "cancel did not return to an empty prompt")
        settle()
        transcript.monitor = True

        edit("print('한글')".encode("utf-8"), len(PROMPT) + 13)
        edit(b"\x1b[D" * 3, len(PROMPT) + 9)
        edit(b"X", len(PROMPT) + 10)
        edit(b"\x1b[3~", len(PROMPT) + 10)  # Delete the next wide character.
        edit(b"\x01", len(PROMPT))  # Ctrl+A: beginning of the draft.
        unchanged(b"\x1b[D")
        unchanged(b"\x7f")
        unchanged(b"\x1b[17~")  # Unbound F6.
        edit(b"\x05", len(PROMPT) + 12)  # Ctrl+E: end of print('한X').
        unchanged(b"\x1b[C")
        unchanged(b"\x1b[3~")
        unchanged(b"\x04")  # Ctrl+D at the end of a nonempty draft.

        transcript.monitor = False
        terminal.send(b"\x03")
        until(lambda: transcript.current_line() == PROMPT.rstrip() and transcript.x == len(PROMPT),
              "cancel did not return to an empty prompt")
        settle()
        transcript.monitor = True
        edit(b"to.", len(PROMPT) + 3, "to.")
        # Listing ambiguous candidates changes the screen even when it does
        # not change the source. The editor must still redraw that source.
        transcript.monitor = False
        before = len(transcript.raw)
        terminal.send(b"\t")
        until(lambda: b"json" in transcript.raw[before:] and b"text" in transcript.raw[before:] and
              transcript.visible and
              transcript.current_line() == PROMPT + "to." and transcript.x == len(PROMPT) + 3,
              "ambiguous Tab listing failed to restore its unchanged draft")
        settle()
        terminal.send(b"\x03")
        until(lambda: transcript.current_line() == PROMPT.rstrip() and transcript.x == len(PROMPT),
              "cancel did not return to an empty prompt")
        settle()
        # An empty continuation can be undone immediately. A second Enter can
        # add another blank line, and each Backspace must remove just one.
        primary_row = transcript.y
        continuation = "... "
        source = "print(#'é'+40+"
        edit(source.encode() + b"\r", len(continuation), "", continuation, primary_row + 1)
        edit(b"\x7f", len(PROMPT + source), source, row=primary_row)
        assert not "".join(transcript.cells[primary_row + 1]).strip(), "stale continuation prompt"

        edit(b"\r\r", len(continuation), "", continuation, primary_row + 2)
        edit(b"2)\x01", len(continuation), "2)", continuation, primary_row + 2)
        edit(b"\x7f", len(continuation), "2)", continuation, primary_row + 1)
        edit(b"\x7f", len(PROMPT + source), source + "2)", row=primary_row)
        assert all(not "".join(cells).strip() for cells in
                   transcript.cells[primary_row + 1:primary_row + 3]), "stale continuation rows"
        # The caret is at the join, so insertion changes the executed result.
        edit(b"1+", len(PROMPT + source + "1+"), source + "1+2)")
        submit("")
        assert "".join(transcript.cells[primary_row + 1]).strip() == "45", "wrong joined command result"
        edit(b"\x1b[A", len(PROMPT + source + "1+2)"), source + "1+2)")
        edit(b"\x1b[B", len(PROMPT), "")
        terminal.send(b"exit(0)\r")
        until(lambda: terminal.poll() is not None, "REPL did not exit")
        assert terminal.poll() == 0
    finally:
        terminal.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    args = parser.parse_args()
    if os.name != "nt":
        print("SKIP: Windows ConPTY prompt transcript")
        return
    check(args.exe.resolve(strict=True))
    print("REPL cursor checks passed: redraws, unchanged keys, Unicode, Ctrl+L, Tab and continuation Backspace")


if __name__ == "__main__":
    main()
