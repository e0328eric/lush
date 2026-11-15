#!/usr/bin/env python3
"""Read real ConPTY screen cells while resizing the REPL, without a VT model.

Run: python tests/repl_resize.py --exe build/lush.exe
A second hidden client observes the same pseudoconsole using read-only Win32
console APIs. No existing user terminal, font, window or desktop is changed.
"""
from __future__ import annotations
import argparse
import ctypes as ct
from ctypes import wintypes as wt
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import time

from integration import ROOT, lua_string
from tui_cursor import Pseudoconsole
from history import width


def observe(directory):
    kernel = ct.WinDLL('kernel32', use_last_error=True)
    class Coord(ct.Structure):
        _fields_ = [('x', ct.c_short), ('y', ct.c_short)]
    class Rect(ct.Structure):
        _fields_ = [(name, ct.c_short) for name in ('left', 'top', 'right', 'bottom')]
    class Info(ct.Structure):
        _fields_ = [('size', Coord), ('cursor', Coord), ('attributes', wt.WORD), ('window', Rect), ('maximum', Coord)]
    class Cursor(ct.Structure):
        _fields_ = [('size', wt.DWORD), ('visible', wt.BOOL)]
    class Character(ct.Union):
        _fields_ = [('unicode', wt.WCHAR), ('ascii', ct.c_char)]
    class Cell(ct.Structure):
        _fields_ = [('character', Character), ('attributes', wt.WORD)]
    kernel.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ct.c_void_p, wt.DWORD, wt.DWORD, wt.HANDLE]
    kernel.CreateFileW.restype = wt.HANDLE
    kernel.GetConsoleScreenBufferInfo.argtypes = [wt.HANDLE, ct.POINTER(Info)]
    kernel.GetConsoleCursorInfo.argtypes = [wt.HANDLE, ct.POINTER(Cursor)]
    kernel.ReadConsoleOutputW.argtypes = [wt.HANDLE, ct.POINTER(Cell), Coord, Coord, ct.POINTER(Rect)]
    kernel.CloseHandle.argtypes = [wt.HANDLE]
    # ConPTY requires a read/write console handle for CursorInfo, even though
    # this helper performs only read operations on the console.
    handle = kernel.CreateFileW('CONOUT$', 0xC0000000, 3, None, 3, 0, None)
    if handle == ct.c_void_p(-1).value:
        raise OSError(ct.get_last_error(), 'observer CONOUT$')
    request, last = directory / 'request', ''
    try:
        while True:
            try:
                current = request.read_text(encoding='ascii')
            except OSError:
                current = ''
            if current == 'quit': return
            if current and current != last and current.isdigit():
                last = current
                try:
                    info, cursor = Info(), Cursor()
                    if not kernel.GetConsoleScreenBufferInfo(handle, ct.byref(info)):
                        raise OSError(ct.get_last_error(), 'observer screen info')
                    if not kernel.GetConsoleCursorInfo(handle, ct.byref(cursor)):
                        raise OSError(ct.get_last_error(), 'observer cursor info')
                    columns = info.window.right - info.window.left + 1
                    rows = info.window.bottom - info.window.top + 1
                    cells = (Cell * (columns * rows))()
                    region = Rect(info.window.left, info.window.top, info.window.right, info.window.bottom)
                    if not kernel.ReadConsoleOutputW(handle, cells, Coord(columns, rows), Coord(0, 0), ct.byref(region)):
                        raise OSError(ct.get_last_error(), 'observer cells')
                    grid = [[('' if cell.attributes & 0x200 else cell.character.unicode or ' ')
                             for cell in cells[row * columns:(row + 1) * columns]] for row in range(rows)]
                    attributes = [[cell.attributes for cell in cells[row * columns:(row + 1) * columns]]
                                  for row in range(rows)]
                    value = {'columns': columns, 'rows': rows, 'cursor': [info.cursor.x - info.window.left,
                             info.cursor.y - info.window.top], 'visible': bool(cursor.visible), 'cells': grid,
                             'attributes': attributes, 'default_attribute': info.attributes}
                except Exception as error:
                    value = {'error': repr(error)}
                target = directory / (current + '.json')
                # Each request has a new filename; publish only after the JSON is complete.
                partial = directory / (current + '.tmp')
                partial.write_text(json.dumps(value, ensure_ascii=True), encoding='ascii')
                partial.rename(target)
            time.sleep(.005)
    finally:
        kernel.CloseHandle(handle)


class Observer:
    def __init__(self, terminal, directory):
        self.terminal, self.directory, self.sequence = terminal, directory, 0
        kernel = self.kernel = terminal.kernel
        StartupEx = kernel.CreateProcessW.argtypes[8]._type_
        ProcessInfo = kernel.CreateProcessW.argtypes[9]._type_
        size = ct.c_size_t()
        kernel.InitializeProcThreadAttributeList(None, 1, 0, ct.byref(size))
        attributes = ct.create_string_buffer(size.value)
        terminal.checked(kernel.InitializeProcThreadAttributeList(attributes, 1, 0, ct.byref(size)), 'observer attributes')
        try:
            terminal.checked(kernel.UpdateProcThreadAttribute(attributes, 0, 0x00020016, terminal.console,
                                                              ct.sizeof(wt.HANDLE), None, None), 'observer pseudoconsole')
            startup, process = StartupEx(), ProcessInfo()
            startup.startup.cb = ct.sizeof(startup)
            startup.startup.flags, startup.startup.show = 1, 0
            startup.attributes = ct.cast(attributes, ct.c_void_p)
            command = ct.create_unicode_buffer(subprocess.list2cmdline(
                [sys.executable, str(Path(__file__).resolve()), '--observer', str(directory)]))
            terminal.checked(kernel.CreateProcessW(sys.executable, command, None, None, False,
                             0x00080000, None, str(directory), ct.byref(startup), ct.byref(process)), 'start observer')
            self.process = process.process
            kernel.CloseHandle(process.thread)
        finally:
            kernel.DeleteProcThreadAttributeList(attributes)

    def snapshot(self):
        self.sequence += 1
        name = str(self.sequence)
        (self.directory / 'request').write_text(name, encoding='ascii')
        target, deadline = self.directory / (name + '.json'), time.monotonic() + 2
        while time.monotonic() < deadline:
            if target.exists():
                value = json.loads(target.read_text(encoding='ascii'))
                target.unlink()
                assert 'error' not in value, value
                return value
            time.sleep(.005)
        raise AssertionError('read-only ConPTY observer did not respond')

    def close(self):
        (self.directory / 'request').write_text('quit', encoding='ascii')
        if self.kernel.WaitForSingleObject(self.process, 2000) != 0:
            self.kernel.TerminateProcess(self.process, 1)
            self.kernel.WaitForSingleObject(self.process, 1000)
        self.kernel.CloseHandle(self.process)


class Session:
    def __init__(self, executable, directory, prefix='zoom> ', left=('H1한글', 'H2'), columns=100, rows=12, colored=False):
        self.executable = executable
        self.prefix, self.left = prefix, left
        configuration = directory / 'init.lua'
        def label(text, background):
            return lua_string(('\x1b[97;' + str(background) + 'm' + text + '\x1b[0m') if colored else text)
        configuration.write_text('lush.config.history_file=false\nlush.config.autosuggestions=true\n'
            'lush.config.syntax_highlighting=false\nlush.config.prompt=function() return {lines={{left=' +
            label(left[0], 41) + ',right=' + label('RIGHT', 44) + '},{left=' + label(left[1], 41) +
            ',right=' + label('END', 44) + '}},input=' +
            lua_string(prefix) + '} end\n', encoding='utf-8')
        self.terminal = Pseudoconsole(executable, None, columns, rows, config_path=configuration,
                                     history_file='', cwd=directory, environment={'TERM': 'xterm-256color'})
        self.observer = None
        self.raw = bytearray()
        self.columns, self.rows, self.last = columns, rows, None
        try:
            self.observer = Observer(self.terminal, directory)
            self.until(lambda value: self.prompt(value, ''), 'initial prompt')
        except BaseException:
            self.close()
            raise

    @staticmethod
    def line(value, row): return ''.join(value['cells'][row]).rstrip()

    def summary(self, value):
        return {'columns': value['columns'], 'rows': value['rows'], 'cursor': value['cursor'],
                'visible': value['visible'], 'lines': [self.line(value, row) for row in range(value['rows'])]}

    def failure(self, description, value):
        summary = self.summary(value)
        artifact = ROOT / 'build' / ('repl-resize-' + self.executable.stem + '-failure.json')
        artifact.write_text(json.dumps({'failure': description, 'screen': summary,
                            'raw_tail': bytes(self.raw[-5000:]).decode('utf-8', errors='replace')},
                            ensure_ascii=True, indent=2), encoding='ascii')
        raise AssertionError((description, summary, str(artifact)))

    def only_prompt(self, value):
        headers = min(2, self.rows - 1)
        y = value['cursor'][1]
        background = value['default_attribute'] & 0xf0
        return all(not self.line(value, row) and all(attribute & 0xf0 == background
                   for attribute in value['attributes'][row]) for row in range(value['rows'])
                   if row < y - headers or row > y)

    def prompt(self, value, draft, prefix=None):
        if prefix is None: prefix = self.prefix
        x, y = value['cursor']
        headers = min(2, self.rows - 1) if prefix == self.prefix else 0
        if value['columns'] != self.columns or value['rows'] != self.rows or not value['visible'] or y < headers:
            return False
        if self.line(value, y) != (prefix + draft).rstrip(): return False
        for index, right in enumerate(('RIGHT', 'END')[:headers]):
            row = value['cells'][y - headers + index]
            if not self.line(value, y - headers + index).startswith(self.left[index]): return False
            if ''.join(row[self.columns - 1 - len(right):self.columns - 1]) != right: return False
        return True

    def header(self, value):
        """Validate the active block without assuming which source suffix is clipped."""
        x, y = value['cursor']
        headers = min(2, self.rows - 1)
        if value['columns'] != self.columns or value['rows'] != self.rows or not value['visible'] or y < headers:
            return False
        label = self.prefix[:self.columns // 2]
        if not self.line(value, y).startswith(label.rstrip()): return False
        for index, full in enumerate(('RIGHT', 'END')[:headers]):
            right = full[:self.columns // 2]
            row = value['cells'][y - headers + index]
            if ''.join(row[self.columns - 1 - len(right):self.columns - 1]) != right: return False
        return 0 <= x < self.columns

    def clean_below(self, value):
        return all(not self.line(value, row) for row in range(value['cursor'][1] + 1, value['rows']))

    def receive(self, timeout=.015):
        data = self.terminal.receive(timeout)
        self.raw.extend(data)
        return data

    def until(self, predicate, description, before=None):
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            self.receive()
            self.last = self.observer.snapshot()
            if (before is None or len(self.raw) > before) and predicate(self.last): return self.last
            if self.terminal.poll() is not None:
                self.failure('REPL exited with ' + str(self.terminal.poll()), self.last)
        self.failure(description, self.last)

    def edit(self, data, draft, caret=None):
        before = len(self.raw)
        self.terminal.send(data.encode('utf-8') if isinstance(data, str) else data)
        return self.until(lambda value: self.prompt(value, draft) and
                          (caret is None or value['cursor'][0] == caret), 'edit ' + repr(draft), before)

    def resize(self, columns, rows):
        coordinate = self.terminal.kernel.CreatePseudoConsole.argtypes[0]
        resize = self.terminal.kernel.ResizePseudoConsole
        resize.argtypes, resize.restype = [wt.HANDLE, coordinate], ct.c_long
        self.columns, self.rows = columns, rows
        status = resize(self.terminal.console, coordinate(columns, rows))
        assert status >= 0, ('ResizePseudoConsole', status)

    def submit(self, source):
        before = len(self.raw)
        self.terminal.send(source.encode('utf-8') + b'\r')
        return self.until(lambda value: self.prompt(value, ''), 'submit ' + source[:40], before)

    def close(self):
        if self.observer is not None: self.observer.close()
        self.terminal.close()


def check(executable):
    with tempfile.TemporaryDirectory(prefix='repl-resize-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        session = Session(executable, directory, colored=True)
        try:
            assert any(attribute & 0xf0 != session.last['default_attribute'] & 0xf0
                       for row in session.last['attributes'] for attribute in row), 'colored fixture was stripped'
            # Initially there is no command output/scrollback. Every nonempty
            # row must therefore belong to the one active prompt, not an old
            # right-side header reflowed into newly created physical rows.
            session.edit('print("한글")', 'print("한글")')
            session.edit(b'\x1b[D' * 3, 'print("한글")', 15)
            for columns, rows in ((40, 12), (100, 12), (24, 12), (80, 12), (120, 16)):
                session.resize(columns, rows)
                value = session.until(lambda value: session.prompt(value, 'print("한글")') and value['cursor'][0] == 15,
                                      f'resized first prompt {columns}x{rows}')
                if not session.only_prompt(value):
                    session.failure('resize left stale rows outside the first active prompt', value)
            # Repeated backend changes may coalesce to the same final size.
            for columns, rows in ((40, 8), (120, 16), (24, 5), (100, 12), (40, 8), (100, 12)):
                session.resize(columns, rows)
            value = session.until(lambda value: session.prompt(value, 'print("한글")') and value['cursor'][0] == 15,
                                  'rapid same-final-size resize')
            if not session.only_prompt(value): session.failure('rapid resize left stale prompt rows', value)
            # At odd widths, a wide glyph at the right margin needs padding;
            # ceil(total_cells / columns) alone does not model native reflow.
            session.resize(100, 96)
            session.until(lambda value: session.prompt(value, 'print("한글")'), 'tall viewport')
            for columns in (7, 3, 5, 7, 100):
                session.resize(columns, 96)
                value = session.until(session.header, 'tiny odd-width resize ' + str(columns))
                if not session.only_prompt(value): session.failure('odd-width reflow left stale prompt rows', value)
            session.edit(b'\x05\x15', '')
            session.submit('print("K")')
            for columns in (3, 100, 7, 100):
                session.resize(columns, 96)
                value = session.until(session.header, 'empty exact-boundary caret ' + str(columns))
                if not any(session.line(value, row) == 'K' for row in range(value['rows'])):
                    session.failure('exact-boundary reflow erased the preceding marker', value)
            session.edit('print("한글")', 'print("한글")')
            session.edit(b'\x1b[D' * 4, 'print("한글")', 13)
            for columns in (7, 100):
                session.resize(columns, 96)
                value = session.until(session.header, 'caret before wide glyph at margin ' + str(columns))
                if not session.clean_below(value): session.failure('wide-glyph margin left old input rows', value)
                if not any(session.line(value, row) == 'K' for row in range(value['rows'])):
                    session.failure('wide-glyph margin erased preceding output', value)
            session.edit(b'\x1b[C', 'print("한글")', 15)
            for rows in (3, 2, 1, 8, 12):
                session.resize(100, rows)
                value = session.until(lambda value: session.prompt(value, 'print("한글")') and value['cursor'][0] == 15,
                                      'header-height resize ' + str(rows))
            session.terminal.send(b'\x03')
            session.until(lambda value: session.prompt(value, ''), 'cancel resized draft')
            # Resizing may erase the active block, never previous command output.
            session.resize(100, 24)
            session.until(lambda value: session.prompt(value, ''), 'restore rows before output')
            session.submit('print("KEEP-RESIZE-MARKER")')
            for columns in (40, 120, 31, 100):
                session.resize(columns, 24)
                value = session.until(lambda value: session.prompt(value, ''), 'preserve earlier output')
                if not any(session.line(value, row) == 'KEEP-RESIZE-MARKER' for row in range(value['rows'])):
                    session.failure('resize erased earlier command output', value)
            # Fill and scroll the actual backend, then edit at its bottom edge.
            before = len(session.raw)
            session.terminal.send(b"for i=1,20 do print('output-'..i) end\r")
            session.until(lambda value: session.prompt(value, '') and value['cursor'][1] == session.rows - 1 and
                          any(session.line(value, row) == 'output-20' for row in range(value['rows'])),
                          'bottom prompt', before)
            session.edit('print("한글")', 'print("한글")')
            session.edit(b'\x1b[D' * 3, 'print("한글")', 15)
            for columns, rows in ((40, 6), (100, 12), (24, 4), (80, 8), (120, 16)):
                session.resize(columns, rows)
                session.until(lambda value: session.prompt(value, 'print("한글")') and value['cursor'][0] == 15,
                              f'resized prompt {columns}x{rows}')
            # Finish the caret edit, then recall the completed Unicode command.
            session.edit('X', 'print("한X글")', 16)
            before = len(session.raw)
            session.terminal.send(b'\r')
            session.until(lambda value: session.prompt(value, ''), 'submit resized Unicode draft', before)
            session.edit(b'\x1b[A', 'print("한X글")')
            for columns, rows in ((40, 8), (100, 12), (31, 6), (120, 16)):
                session.resize(columns, rows)
                session.until(lambda value: session.prompt(value, 'print("한X글")'), 'resize recalled history')
            session.edit(b'\x1b[B', '')
            # Continuation text remains a Lua chunk across row/column changes.
            session.terminal.send(b'function resize_pending(x)\r')
            session.until(lambda value: session.prompt(value, '', prefix='... '), 'continuation prompt')
            session.terminal.send(b'return x+1')
            session.until(lambda value: session.prompt(value, 'return x+1', prefix='... '), 'continuation draft')
            for columns, rows in ((24, 3), (100, 9), (40, 2), (120, 16)):
                session.resize(columns, rows)
                session.until(lambda value: session.prompt(value, 'return x+1', prefix='... '), 'resize continuation')
            session.terminal.send(b'\rend\r')
            session.until(lambda value: session.prompt(value, ''), 'complete resized continuation')
            session.submit('assert(resize_pending(41)==42)')
            # A long painted suffix/ghost can extend well beyond a midline caret.
            result_file = directory / 'unicode-result.txt'
            payload = '한글abc' * 22
            source = 'lush.write(' + lua_string(result_file) + ',' + lua_string(payload) + ')'
            session.resize(400, 24)
            session.until(lambda value: session.prompt(value, ''), 'wide long-input viewport')
            before = len(session.raw)
            session.terminal.send(source.encode('utf-8'))
            session.until(lambda value: session.header(value) and
                          session.line(value, value['cursor'][1]).endswith(source[-20:]), 'long Unicode draft', before)
            # Move to a known position inside the payload, preserving source data.
            scalar_offset = source.index(payload) + 5
            before = len(session.raw)
            session.terminal.send(b'\x01' + b'\x1b[C' * scalar_offset)
            expected_caret = len('zoom> ') + width(source[:scalar_offset])
            session.until(lambda value: session.header(value) and value['cursor'][0] == expected_caret,
                          'midline long Unicode caret', before)
            for columns, rows in ((31, 8), (100, 12), (40, 4), (120, 16)):
                session.resize(columns, rows)
                value = session.until(session.header, 'resize long Unicode tail')
                if not session.clean_below(value): session.failure('resize left old input-tail rows below caret', value)
            session.terminal.send(b'X\r')
            session.until(lambda value: session.prompt(value, ''), 'execute resized long draft')
            assert result_file.read_text(encoding='utf-8') == payload[:5] + 'X' + payload[5:], 'logical caret/source changed on resize'
            result_file.unlink()
            session.terminal.send(b'lush.write(')
            session.until(lambda value: session.header(value) and value['cursor'][0] == 17 and
                          len(session.line(value, value['cursor'][1])) > len('zoom> lush.write('), 'history ghost')
            for columns, rows in ((31, 8), (100, 12), (40, 4), (120, 16)):
                session.resize(columns, rows)
                value = session.until(lambda value: session.header(value) and value['cursor'][0] == 17, 'resize history ghost')
                if not session.clean_below(value): session.failure('resize left old ghost rows below caret', value)
            session.terminal.send(b'\x1b[C\r')
            session.until(lambda value: session.prompt(value, ''), 'accept resized ghost')
            assert result_file.read_text(encoding='utf-8') == payload[:5] + 'X' + payload[5:]
            # Put the caret immediately before a wide ghost character at a
            # reflow margin (old prefix width7 => new width4 leaves one cell).
            session.resize(100, 128)
            session.until(lambda value: session.prompt(value, ''), 'restore wide ghost viewport')
            session.submit('"한글"')
            session.submit('print("G")')
            session.terminal.send(b'"')
            session.until(lambda value: session.header(value) and value['cursor'][0] == 7 and
                          session.line(value, value['cursor'][1]).endswith('"한글"'), 'wide-character ghost boundary')
            for columns, rows in ((4, 128), (100, 128), (3, 128), (100, 128), (5, 128), (100, 24)):
                session.resize(columns, rows)
                value = session.until(session.header, 'resize wide ghost boundary ' + str(columns))
                if not session.clean_below(value): session.failure('wide ghost reflow left rows below caret', value)
                if not any(session.line(value, row) == 'G' for row in range(value['rows'])):
                    session.failure('wide ghost reflow erased preceding output', value)
            session.terminal.send(b'\x1b[C\r')
            session.until(lambda value: session.prompt(value, ''), 'accept wide ghost after resize')
        finally:
            session.close()
        # The old theme test's VT model cannot reflow ConPTY's full resize
        # repaint. Observe this exact completion/header case natively instead.
        tab_directory = directory / 'tab-case'
        tab_directory.mkdir()
        tab = Session(executable, tab_directory, prefix='custom> ', left=('LEFT한글 KEEP', 'SECOND'), columns=120, rows=60)
        try:
            tab.edit('to.', 'to.', 11)
            before = len(tab.raw)
            tab.terminal.send(b'\t')
            choices = lambda value: any('json' in tab.line(value, row) and 'text' in tab.line(value, row)
                                       for row in range(value['cursor'][1] - 2))
            tab.until(lambda value: tab.prompt(value, 'to.') and value['cursor'][0] == 11 and choices(value),
                      'Tab choices with fresh prompt headers', before)
            tab.resize(80, 60)
            value = tab.until(lambda value: tab.prompt(value, 'to.') and value['cursor'][0] == 11 and choices(value),
                              'Tab choices survive120-to80 resize')
            if not tab.clean_below(value): tab.failure('Tab resize left stale input rows', value)
            tab.edit('json', 'to.json', 15)
            tab.edit(b'\x05\x15', '')
        finally:
            tab.close()
        print('ConPTY resize checks passed: native reflow, rapid/tiny geometry, scrollback, Unicode, history, ghost, continuation and Tab')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    parser.add_argument('--observer', type=Path, help=argparse.SUPPRESS)
    args = parser.parse_args()
    if os.name != 'nt': print('SKIP: Windows ConPTY resize regression'); return
    if args.observer is not None: observe(args.observer); return
    check(args.exe.resolve(strict=True))


if __name__ == '__main__': main()
