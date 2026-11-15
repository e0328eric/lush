"""Exercise Lush in an isolated, hidden Windows console using only the stdlib.

Run: python tests/windows_console.py [--exe build/lush.exe]
No visible windows or input events are sent to an existing user terminal.
"""

from __future__ import annotations

import argparse
import ctypes as ct
from ctypes import wintypes as wt
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
import time


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path,
                        default=Path(__file__).resolve().parents[1] / "build/lush.exe")
    parser.add_argument("--worker", action="store_true", help=argparse.SUPPRESS)
    args = parser.parse_args()
    if sys.platform != "win32":
        print("SKIP: native Windows console test")
        return
    executable = args.exe.resolve(strict=True)
    if not args.worker:
        # Detaching a process invalidates its console standard handles. Keep
        # the user's Python process attached and run Win32 work with pipes.
        worker = subprocess.Popen(
            [sys.executable, str(Path(__file__).resolve()), "--worker", "--exe", str(executable)],
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
            encoding="utf-8", errors="replace",
        )
        try:
            output, errors = worker.communicate(timeout=150)
        except subprocess.TimeoutExpired:
            # Both the holder and shell belong to this worker's process tree.
            subprocess.run(["taskkill.exe", "/PID", str(worker.pid), "/T", "/F"],
                           capture_output=True, timeout=10,
                           creationflags=subprocess.CREATE_NO_WINDOW)
            worker.communicate(timeout=5)
            raise RuntimeError("native console test exceeded its overall timeout") from None
        sys.stdout.write(output)
        sys.stderr.write(errors)
        if worker.returncode:
            raise SystemExit(worker.returncode)
        return
    fixtures = tempfile.TemporaryDirectory(prefix="lush-console-completion-")
    fixture_root = Path(fixtures.name)
    executable_directory = fixture_root / "quoted; PATH directory"
    executable_directory.mkdir()
    duplicate_directory = fixture_root / "second PATH directory"
    duplicate_directory.mkdir()
    shutil.copyfile(executable, executable_directory / "luish-completion-tool.exe")
    for name in ("LushAlpha.EXE", "lush-beta.exe", "tool-1.2.exe", "script.cmd",
                 "batch.BAT", "command.COM", "ignored.py", "document.txt",
                 "lush_choice_alpha.exe", "lush_choice_beta.exe"):
        (executable_directory / name).touch()
    (executable_directory / "not-an-executable.exe").mkdir()
    (duplicate_directory / "lushalpha.exe").touch()
    (fixture_root / "cwd-shadow.exe").touch()
    (fixture_root / "quoted 한글 name.txt").write_text("completed-file-marker\n", encoding="utf-8")
    (fixture_root / "folder 한글").mkdir()
    (fixture_root / "folder 한글" / "inside.txt").write_text("completed-directory-marker\n", encoding="utf-8")
    mouse_directory = fixture_root / "mouse input records"
    mouse_directory.mkdir()
    for index in range(40):
        (mouse_directory / f"item-{index:02}.txt").touch()
    console_configuration = fixture_root / "console-init.lua"
    console_configuration.write_text("lush.config.autosuggestions = false\n", encoding="utf-8")
    console_environment = dict(os.environ, LUSH_HISTORY_FILE=str(fixture_root / "history.jsonl"))

    def executable_candidates(prefix: str = "", **changes: str) -> list[str]:
        environment = dict(os.environ, PATH=f'"{executable_directory}";{duplicate_directory};;'
                           f'"{executable_directory}"', PATHEXT=".COM;.EXE;.BAT;.CMD;.PY")
        environment.update(changes)
        code = "print(json.encode(_lush.executables(" + json.dumps(prefix) + ")))"
        completed = subprocess.run([str(executable), "--no-config", "-c", code],
                                   env=environment, cwd=fixture_root, capture_output=True,
                                   text=True, encoding="utf-8", timeout=10)
        assert completed.returncode == 0, (completed.stdout, completed.stderr)
        return json.loads(completed.stdout)

    names = executable_candidates()
    assert names == ["batch.BAT", "command.COM", "luish-completion-tool", "lush-beta",
                     "LushAlpha", "lush_choice_alpha", "lush_choice_beta",
                     "script.cmd", "tool-1.2.exe"], names
    assert executable_candidates("LUSHAL") == ["LushAlpha"]
    assert executable_candidates(PATHEXT=".CMD") == ["script.cmd"]
    assert executable_candidates(PATH="") == []
    assert executable_candidates(PATH=".") == ["cwd-shadow"]

    kernel = ct.WinDLL("kernel32", use_last_error=True)

    class Coord(ct.Structure):
        _fields_ = [("x", ct.c_short), ("y", ct.c_short)]

    class Rect(ct.Structure):
        _fields_ = [(name, ct.c_short) for name in ("left", "top", "right", "bottom")]

    class ScreenInfo(ct.Structure):
        _fields_ = [("size", Coord), ("cursor", Coord), ("attributes", wt.WORD),
                    ("window", Rect), ("maximum", Coord)]

    class CursorInfo(ct.Structure):
        _fields_ = [("size", wt.DWORD), ("visible", wt.BOOL)]

    class Character(ct.Union):
        _fields_ = [("unicode", wt.WCHAR), ("ascii", ct.c_char)]

    class KeyEvent(ct.Structure):
        _fields_ = [("down", wt.BOOL), ("repeat", wt.WORD), ("vk", wt.WORD),
                    ("scan", wt.WORD), ("character", Character), ("modifiers", wt.DWORD)]

    class MouseEvent(ct.Structure):
        _fields_ = [("position", Coord), ("buttons", wt.DWORD),
                    ("modifiers", wt.DWORD), ("flags", wt.DWORD)]

    class Event(ct.Union):
        _fields_ = [("key", KeyEvent), ("mouse", MouseEvent), ("padding", ct.c_byte * 16)]

    class InputRecord(ct.Structure):
        _fields_ = [("kind", wt.WORD), ("event", Event)]

    class Cell(ct.Structure):
        _fields_ = [("character", Character), ("attributes", wt.WORD)]

    kernel.CreateFileW.argtypes = [wt.LPCWSTR, wt.DWORD, wt.DWORD, ct.c_void_p,
                                  wt.DWORD, wt.DWORD, wt.HANDLE]
    kernel.CreateFileW.restype = wt.HANDLE
    kernel.AttachConsole.argtypes = [wt.DWORD]
    kernel.AttachConsole.restype = wt.BOOL
    kernel.GetConsoleScreenBufferInfo.argtypes = [wt.HANDLE, ct.POINTER(ScreenInfo)]
    kernel.GetConsoleCursorInfo.argtypes = [wt.HANDLE, ct.POINTER(CursorInfo)]
    kernel.GetConsoleTitleW.argtypes = [wt.LPWSTR, wt.DWORD]
    kernel.GetNumberOfConsoleInputEvents.argtypes = [wt.HANDLE, ct.POINTER(wt.DWORD)]
    kernel.ReadConsoleOutputW.argtypes = [wt.HANDLE, ct.POINTER(Cell), Coord,
                                         Coord, ct.POINTER(Rect)]
    kernel.WriteConsoleInputW.argtypes = [wt.HANDLE, ct.POINTER(InputRecord),
                                         wt.DWORD, ct.POINTER(wt.DWORD)]
    kernel.GetConsoleMode.argtypes = [wt.HANDLE, ct.POINTER(wt.DWORD)]
    kernel.SetConsoleMode.argtypes = [wt.HANDLE, wt.DWORD]
    kernel.GenerateConsoleCtrlEvent.argtypes = [wt.DWORD, wt.DWORD]
    kernel.CloseHandle.argtypes = [wt.HANDLE]
    handler_type = ct.WINFUNCTYPE(wt.BOOL, wt.DWORD)
    kernel.SetConsoleCtrlHandler.argtypes = [handler_type, wt.BOOL]

    @handler_type
    def control_handler(event: int) -> bool:
        # Consume our copy, while exec'd children receive the same event.
        return event in (0, 1)

    def checked(success: int, operation: str) -> None:
        if not success:
            raise OSError(ct.get_last_error(), operation)

    startup = subprocess.STARTUPINFO()
    startup.dwFlags = subprocess.STARTF_USESHOWWINDOW
    startup.wShowWindow = 0  # SW_HIDE: this console never becomes visible.
    holder_code = (
        "import ctypes,time; "
        "ctypes.windll.kernel32.SetConsoleCtrlHandler(None,True); time.sleep(120)"
    )
    holder = subprocess.Popen([sys.executable, "-c", holder_code],
                              creationflags=subprocess.CREATE_NEW_CONSOLE,
                              startupinfo=startup)
    process: subprocess.Popen | None = None
    input_handle = output_handle = None
    original_input_cp = original_output_cp = None
    original_input_mode = original_output_mode = None
    registered = False
    attached = False
    try:
        # Only this test subprocess detaches. Its stdout/stderr remain pipes
        # when called by another test runner.
        kernel.FreeConsole()
        deadline = time.monotonic() + 8
        while not kernel.AttachConsole(holder.pid):
            if holder.poll() is not None or time.monotonic() >= deadline:
                raise RuntimeError("could not attach the hidden test console")
            time.sleep(.05)
        attached = True
        input_handle = kernel.CreateFileW("CONIN$", 0xC0000000, 3, None, 3, 0, None)
        output_handle = kernel.CreateFileW("CONOUT$", 0xC0000000, 3, None, 3, 0, None)
        invalid_handle = ct.c_void_p(-1).value
        if input_handle in (None, invalid_handle) or output_handle in (None, invalid_handle):
            raise OSError(ct.get_last_error(), "open hidden console handles")

        def mode(handle: int) -> int:
            value = wt.DWORD()
            checked(kernel.GetConsoleMode(handle, ct.byref(value)), "GetConsoleMode")
            return value.value

        original_input_cp = kernel.GetConsoleCP()
        original_output_cp = kernel.GetConsoleOutputCP()
        original_input_mode = mode(input_handle)
        original_output_mode = mode(output_handle)
        # Deliberately choose a non-UTF-8 baseline to exercise restoration.
        checked(kernel.SetConsoleCP(437), "SetConsoleCP")
        checked(kernel.SetConsoleOutputCP(437), "SetConsoleOutputCP")
        checked(kernel.SetConsoleCtrlHandler(control_handler, True), "register test handler")
        registered = True

        def console_info() -> ScreenInfo:
            info = ScreenInfo()
            checked(kernel.GetConsoleScreenBufferInfo(output_handle, ct.byref(info)),
                    "GetConsoleScreenBufferInfo")
            return info

        def screen() -> str:
            info = console_info()
            columns, rows = info.size.x, min(info.size.y, 300)
            cells = (Cell * (columns * rows))()
            region = Rect(0, 0, columns - 1, rows - 1)
            checked(kernel.ReadConsoleOutputW(output_handle, cells, Coord(columns, rows),
                                             Coord(0, 0), ct.byref(region)), "ReadConsoleOutputW")
            # Read cells, not ReadConsoleOutputCharacterW: the latter loses
            # column positions for double-width characters such as Korean.
            lines = []
            for start in range(0, len(cells), columns):
                lines.append("".join(cell.character.unicode
                                     for cell in cells[start:start + columns]
                                     if not cell.attributes & 0x200).rstrip())
            return "\n".join(lines).strip()

        def wait_for(token: str, count: int = 1) -> str:
            deadline = time.monotonic() + 8
            while time.monotonic() < deadline:
                value = screen()
                if value.count(token) >= count:
                    return value
                if process is not None and process.poll() is not None:
                    raise AssertionError(("unexpected shell exit", process.returncode, ascii(value)))
                time.sleep(.025)
            raise AssertionError(("console output missing", ascii(token), ascii(screen())))

        def key(vk: int, character: str = "\0", modifiers: int = 0) -> None:
            records = (InputRecord * 2)()
            for index in range(2):
                records[index].kind = 1  # KEY_EVENT
                records[index].event.key = KeyEvent(index == 0, 1, vk, 0,
                                                   Character(unicode=character), modifiers)
            written = wt.DWORD()
            checked(kernel.WriteConsoleInputW(input_handle, records, 2, ct.byref(written)),
                    "WriteConsoleInputW")
            assert written.value == 2

        def mouse_events(events: list[tuple[int, int, int, int]]) -> None:
            # Queue synthetic console records, not OS desktop pointer input.
            # Coordinates are relative to the application's current viewport.
            info = console_info()
            records = (InputRecord * len(events))()
            for record, (x, y, buttons, flags) in zip(records, events):
                record.kind = 2  # MOUSE_EVENT
                record.event.mouse = MouseEvent(
                    Coord(x + info.window.left, y + info.window.top), buttons, 0, flags,
                )
            written = wt.DWORD()
            checked(kernel.WriteConsoleInputW(input_handle, records, len(records), ct.byref(written)),
                    "WriteConsoleInputW mouse records")
            assert written.value == len(records)

        def wait_input_idle() -> None:
            deadline = time.monotonic() + 3
            empty_samples = 0
            while time.monotonic() < deadline:
                count = wt.DWORD()
                checked(kernel.GetNumberOfConsoleInputEvents(input_handle, ct.byref(count)),
                        "GetNumberOfConsoleInputEvents")
                empty_samples = empty_samples + 1 if count.value == 0 else 0
                if empty_samples == 3:
                    return
                time.sleep(.025)
            raise AssertionError("console input queue did not drain promptly")

        def text_caret() -> tuple[int, int, int, bool]:
            info, cursor = console_info(), CursorInfo()
            checked(kernel.GetConsoleCursorInfo(output_handle, ct.byref(cursor)), "GetConsoleCursorInfo")
            return info.cursor.x, info.cursor.y, cursor.size, bool(cursor.visible)

        def console_title() -> str:
            title = ct.create_unicode_buffer(512)
            kernel.GetConsoleTitleW(title, len(title))
            return title.value

        def text(value: str) -> None:
            for character in value:
                vk = ord(character.upper()) if character.isascii() and character.isalpha() else 0
                key(vk, character)

        def enter() -> None:
            key(13, "\r")

        def launch(*arguments: str) -> subprocess.Popen:
            child_startup = subprocess.STARTUPINFO()
            child_startup.dwFlags = subprocess.STARTF_USESTDHANDLES | subprocess.STARTF_USESHOWWINDOW
            child_startup.wShowWindow = 0
            child_startup.hStdInput = input_handle
            child_startup.hStdOutput = output_handle
            child_startup.hStdError = output_handle
            child_startup.lpAttributeList = {"handle_list": [input_handle, output_handle]}
            for handle in (input_handle, output_handle):
                os.set_handle_inheritable(handle, True)
            try:
                return subprocess.Popen([str(executable), "--config", str(console_configuration), *arguments],
                                        startupinfo=child_startup, close_fds=True, env=console_environment)
            finally:
                for handle in (input_handle, output_handle):
                    os.set_handle_inheritable(handle, False)

        def assert_restored() -> None:
            assert kernel.GetConsoleCP() == 437, "input code page was not restored"
            assert kernel.GetConsoleOutputCP() == 437, "output code page was not restored"
            assert mode(input_handle) == original_input_mode, "input mode was not restored"
            assert mode(output_handle) == original_output_mode, "output mode was not restored"

        process = launch()
        wait_for(" >")
        assert kernel.GetConsoleOutputCP() == 65001
        assert kernel.GetConsoleCP() == 65001
        text("1+2"); enter(); wait_for("\n3\n")
        key(38); enter(); wait_for("\n3\n", 2)  # Up recalls the prior submission.
        text("print('한글')"); enter(); wait_for("\n한글\n")
        text("print('first\\nsecond')"); enter(); wait_for("\nfirst\nsecond\n")
        text("1+24"); key(37); key(46); enter(); wait_for("\n3\n", 3)
        text("function cancelled()"); enter(); wait_for("\n...")
        key(67, "\x03", 8); wait_for("^C")

        # Put one marker into scrollback and another on the visible screen.
        # Ctrl+L should clear only the screen and retain the in-progress edit.
        scrollback_marker = "ctrl-l-scrollback-marker-59473"
        visible_marker = "ctrl-l-screen-marker-59473"
        text("print('" + scrollback_marker + "')"); enter()
        wait_for("\n" + scrollback_marker + "\n")
        info = console_info()
        fill_count = info.window.bottom - info.window.top + 11
        text("for i=1," + str(fill_count) + " do print('scroll-fill-'..i) end")
        enter(); wait_for("\nscroll-fill-" + str(fill_count) + "\n")
        text("print('" + visible_marker + "')"); enter()
        wait_for("\n" + visible_marker + "\n")
        text("20+()"); key(37)  # Leave the caret before the closing parenthesis.
        wait_for(" > 20+()")
        caret_column = console_info().cursor.x
        key(76, "\x0c", 8)  # Ctrl+L
        deadline = time.monotonic() + 8
        while time.monotonic() < deadline:
            cleared = screen()
            if visible_marker not in cleared and " > 20+()" in cleared:
                break
            time.sleep(.025)
        else:
            raise AssertionError(("Ctrl+L did not clear and redraw", ascii(screen())))
        assert scrollback_marker in cleared, "Ctrl+L erased scrollback"
        info = console_info()
        assert info.cursor.x == caret_column, "Ctrl+L moved the editing caret"
        assert info.cursor.y == info.window.top, "Ctrl+L did not redraw at screen home"
        text("12"); enter(); wait_for("\n32\n")

        # Native command completion follows the shell's *current* PATH and
        # rewrites hyphenated executable names into valid Lua indexing syntax.
        text("completion_original_path=env.PATH; completion_original_cwd=pwd(); env.PATH=" +
             json.dumps('"' + str(executable_directory) + '"') + "; cd(" +
             json.dumps(str(fixture_root)) + "); print('completion-fixtures-ready')")
        enter(); wait_for("\ncompletion-fixtures-ready\n")
        text("cmd.luish"); key(9, "\t")
        wait_for('cmd["luish-completion-tool"]')
        text("('--no-config','-c',\"print('completed-executable-marker')\")")
        enter(); wait_for("\ncompleted-executable-marker\n")

        # A completion in the middle must preserve the rest of the Lua line.
        text('print(cat("quoted "))')
        key(37); key(37); key(37)  # Before the closing quote and two parentheses.
        key(9, "\t"); wait_for("quoted 한글 name.txt")
        enter(); wait_for("\ncompleted-file-marker\n")

        text('cd("fol'); key(9, "\t"); wait_for("folder 한글")
        text('")'); enter()
        text("print(cat('inside.txt'))"); enter(); wait_for("\ncompleted-directory-marker\n")
        text("cd(" + json.dumps(str(fixture_root)) + ")"); enter()

        # Two names produce suggestions; Tab must neither execute either
        # candidate nor replace the line with an arbitrary choice.
        text("cmd.lush_choice_"); key(9, "\t")
        wait_for("lush_choice_alpha"); wait_for("lush_choice_beta")
        key(67, "\x03", 8)
        text('print("no-match-completion-marker")')
        key(37); key(37)  # Before the string's closing quote and print's ')'.
        key(9, "\t"); enter(); wait_for("\nno-match-completion-marker\n")
        text("env.PATH=completion_original_path; cd(completion_original_cwd)"); enter()

        # Input regression: hover and drag events must not select files. This
        # tests the native input queue without moving the physical mouse pointer.
        tui_prompts = screen().count(" >")
        text("ls('--tui'," + json.dumps(str(mouse_directory)) + ")"); enter()
        wait_for("1/40")

        def selected_index() -> int:
            positions = re.findall(r"(?m)^\s*(\d+)/40(?:\s|$)", screen())
            assert positions, ("TUI position missing", ascii(screen()))
            return int(positions[-1])

        def assert_idle_tui(index: int, caret: tuple[int, int, int, bool], title: str) -> None:
            wait_input_idle()
            assert selected_index() == index, "pointer motion changed the file selection"
            assert text_caret() == caret, "ignored pointer motion moved the text caret"
            assert console_title() == title, "ignored pointer motion changed the console title"

        wait_input_idle()
        initial_caret, initial_title = text_caret(), console_title()
        info = console_info()
        mouse_rows = max(1, info.window.bottom - info.window.top - 2)
        motion = [(4 + index % 20, 1 + index % mouse_rows, 0, 1) for index in range(100)]
        mouse_events(motion)
        assert_idle_tui(1, initial_caret, initial_title)
        drag = [(4 + index % 20, 1 + index % mouse_rows, 1 if index < 50 else 2, 1)
                for index in range(100)]
        mouse_events(drag + [(4, 1, 0, 0)])  # Release the drag; no click was sent.
        assert_idle_tui(1, initial_caret, initial_title)

        wheel_down = (-120 & 0xffff) << 16
        mouse_events([(8, 8, wheel_down, 4)])
        wait_for("4/40"); wait_input_idle()
        after_wheel_caret = text_caret()
        # A stale high word alone is not a wheel event: the event flags decide.
        mouse_events([(x, y, wheel_down, flags) for x, y, _, flags in motion])
        assert_idle_tui(4, after_wheel_caret, initial_title)
        mouse_events([(8, 8, 1, 0), (8, 8, 0, 0)])
        wait_for("8/40")
        mouse_events([(8, 10, 2, 0), (8, 10, 0, 0)])
        wait_for("10/40"); wait_for("1 selected")
        mouse_events([(8, 10, 2, 0), (8, 10, 0, 0)])
        wait_input_idle()
        assert "1 selected" not in screen(), "right click did not toggle the mark off"
        mouse_events([(8, 10, 120 << 16, 4)])
        wait_for("7/40")
        text("q"); wait_for(" >", tui_prompts + 1)
        text("print('tui-input-returned-to-shell')"); enter()
        wait_for("\ntui-input-returned-to-shell\n")

        # Exercise the actual terminal renderer rather than snapshot output.
        # Motion floods must not starve signal-mode interruption or leak into
        # the prompt after the animation releases its terminal session.
        animation_prompts = screen().count(" >")
        text("ls('--lol=signal')"); enter(); wait_for("|fls")
        interrupted = time.monotonic()
        mouse_events(motion)
        key(67, "\x03", 8)
        wait_for(" >", animation_prompts + 1)
        assert time.monotonic() - interrupted < 3, "animation input flood delayed interruption"
        text("print('animation-returned-to-shell')"); enter()
        wait_for("\nanimation-returned-to-shell\n")

        child_code = "import time; print('external-child-ready',flush=True); time.sleep(30)"
        command = "run{" + ",".join(json.dumps(item) for item in
                                    (sys.executable, "-c", child_code)) + "}"
        text(command); enter(); wait_for("\nexternal-child-ready")
        prompt_count = screen().count(" >")
        checked(kernel.GenerateConsoleCtrlEvent(0, 0), "GenerateConsoleCtrlEvent")
        wait_for(" >", prompt_count + 1)
        text("6*7"); enter(); wait_for("\n42\n")
        key(68, "\x04", 8)
        assert process.wait(timeout=8) == 0
        assert_restored()

        for source, expected in (("exit(23)", 23),
                                 ("error('expected-console-error')", 1),
                                 ("os.exit(0)", 0),
                                 ("io.write('한글')", 0)):
            process = launch("-c", source)
            assert process.wait(timeout=8) == expected, source
            assert_restored()
        print("Windows console checks passed: editing, history, Unicode, Ctrl+L, executable/path completion, "
              "TUI mouse input, animation input flood/interruption, child interrupt, exit and restoration")
    finally:
        if process is not None and process.poll() is None:
            process.kill()
            process.wait(timeout=5)
        if attached:
            if original_input_mode is not None:
                kernel.SetConsoleMode(input_handle, original_input_mode)
            if original_output_mode is not None:
                kernel.SetConsoleMode(output_handle, original_output_mode)
            if original_input_cp:
                kernel.SetConsoleCP(original_input_cp)
            if original_output_cp:
                kernel.SetConsoleOutputCP(original_output_cp)
            if registered:
                kernel.SetConsoleCtrlHandler(control_handler, False)
        for handle in (input_handle, output_handle):
            if handle not in (None, ct.c_void_p(-1).value):
                kernel.CloseHandle(handle)
        kernel.FreeConsole()
        if holder.poll() is None:
            holder.kill()
        holder.wait(timeout=5)
        fixtures.cleanup()


if __name__ == "__main__":
    main()
