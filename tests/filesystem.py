#!/usr/bin/env python3
"""Exercise filesystem builtins in an isolated build directory.

Run: python tests/filesystem.py --exe build/lush.exe
"""
from __future__ import annotations

import argparse
import filecmp
import os
from pathlib import Path
import re
import subprocess
import tempfile
import time

from integration import ROOT, Suite, lua_string


class Statements(Suite):
    def check(self, source, expected=None, **options):
        # A successful assert(...) is itself an expression that the REPL displays.
        return super().check('do\n' + source + '\nend', expected, **options)


def check_home_paths(suite):
    variable, other = ('USERPROFILE', 'HOME') if os.name == 'nt' else ('HOME', 'USERPROFILE')
    token = '%LUSH_TOKEN%' if os.name == 'nt' else '$LUSH_TOKEN'
    home = suite.directory / f'home with spaces {token}'
    home.mkdir()
    environment = dict(os.environ, LUSH_TOKEN='substituted')
    environment.update({variable: str(home), other: str(suite.directory)})

    suite.check(f'''
        local original = pwd()
        cd('~')
        assert(pwd() == {lua_string(home.as_posix())})
        cd(original)
        cd()
        assert(pwd() == {lua_string(home.as_posix())})
        cd(original)
        assert(path.expand('~') == {lua_string(home)})
        assert(path.expand('~/{token}') == {lua_string(home / 'substituted')})
        mkdir('~/work')
        cd('~/work')
        assert(pwd() == {lua_string((home / 'work').as_posix())})
        cd(original)
        touch('~/work/new')
        lush.write('~/work/new', 'return ')
        show(stream{{'42'}} | save('~/work/new', true))
        cp('~/work/new', '~/work/copied')
        mv('~/work/copied', '~/work/moved')
        assert(source('~/work/moved') == 42)
        assert(stat('~/work/moved').size == #cat('~/work/new'))
        rm('~/work/new')
        assert(not exists('~/work/new') and path.exists('~/work/moved'))
        touch('~/work/~')
        local names = ls('-I', '~', '--', '~/work'):get('name'):collect()
        assert(#names == 1 and names[1] == 'moved')
        assert(ls('~/work', true):count() >= 2)
        assert(lush.complete('cd("~/wo')[1] == 'cd("~/work/')
        assert(lush.complete('cat("~')[1] == 'cat("~/')
        _lush.open = function(target) return target end
        assert(open('~/work/moved') == stat('~/work/moved').path)
        touch('~/{token}')
        mkdir('./~')
        touch('./~/literal')
        touch('~draft')
    ''', '', environment=environment)
    assert (home / token).is_file() and (home / 'work/moved').read_text() == 'return 42'
    assert (suite.directory / '~/literal').is_file() and (suite.directory / '~draft').is_file()
    suite.check("show(ls('-1', '-I', '~', '~/work'))", 'moved\n', environment=environment)
    browser = suite.check("show(ls('--snapshot', '--keys=c~/work<Enter>'))", environment=environment)
    assert 'moved' in browser.stdout

    suite.check(r"touch([[~\backslash]])", '', environment=environment)
    expected = home / 'backslash' if os.name == 'nt' else suite.directory / r'~\backslash'
    assert expected.is_file()

    suite.check(f'''
        env.{variable} = {lua_string(str(home) + os.sep)}
        assert(path.exists('~/work/moved'))
        env.{variable} = nil
        local ok, message = pcall(rm, '~/literal')
        assert(not ok and message:find('{variable}', 1, true))
        assert(exists('./~/literal'))
    ''', '', environment=environment)

    executable = '~/' + suite.executable.name
    suite.check(f'''
        env.{variable} = {lua_string(suite.executable.parent)}
        local program = {lua_string(executable)}
        assert(which(program) == {lua_string(suite.executable)})
        local child = capture(cmd[program]('--no-config', '-c', 'print(arg[1])', '--', '~/literal'))
        assert(child:check().stdout == '~/literal\\n')
    ''', '', environment=environment)


def terminal_run(suite, code, directory):
    from repl_cursor import PromptTranscript
    from tui_cursor import Pseudoconsole

    terminal = Pseudoconsole(suite.executable, code, 100, 30, cwd=directory)
    trace = PromptTranscript(100, 30)
    try:
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            data = terminal.receive()
            trace.feed(data)
            if terminal.poll() is not None and not data:
                break
        assert terminal.poll() == 0, bytes(trace.raw[-1500:])
        return trace
    finally:
        terminal.close()


def check_case_sensitive_copy(suite):
    include = suite.directory / 'case-source' / 'include'
    include.mkdir(parents=True)
    headers = {'xt_CONNMARK.h': b'uppercase header\n', 'xt_connmark.h': b'lowercase header\n'}
    if os.name == 'nt':
        # fsutil can exit successfully while reporting an access error. Verify
        # the actual behavior by creating both files with exclusive create.
        enable = subprocess.run(['fsutil', 'file', 'setCaseSensitiveInfo', str(include), 'enable'],
                                capture_output=True, text=True, errors='replace')
    for name, data in headers.items():
        try:
            with (include / name).open('xb') as stream:
                stream.write(data)
        except FileExistsError:
            if os.name == 'nt':
                print('Case-sensitive fixture unavailable:', (enable.stdout + enable.stderr).strip())
            else:
                print('Case-sensitive fixture unavailable: filesystem aliases the two header names')
            return

    for name in ('ABI', 'abi'):
        child = include / name
        child.mkdir()
        (child / 'kind').write_text(name)

    copied = suite.directory / 'case-copy' / 'include'
    suite.check("assert(cp('case-source','case-copy',{recursive=true}))", '')
    assert {item.name for item in copied.iterdir()} == set(headers) | {'ABI', 'abi'}
    for name, data in headers.items():
        assert (copied / name).read_bytes() == data
    for name in ('ABI', 'abi'):
        assert (copied / name / 'kind').read_text() == name

    (copied / 'xt_connmark.h').write_bytes(b'existing lower')
    (copied / 'retained').write_bytes(b'keep')
    suite.check("assert(not pcall(cp,'case-source','case-copy',{recursive=true}))", '')
    assert (copied / 'xt_connmark.h').read_bytes() == b'existing lower'
    suite.check("assert(cp('case-source','case-copy',{recursive=true,overwrite=true}))", '')
    for name, data in headers.items():
        assert (copied / name).read_bytes() == data
    assert (copied / 'retained').read_bytes() == b'keep'

    # A populated destination can still have its original case-insensitive
    # behavior. It must never collapse a pair while merging with overwrite.
    if os.name == 'nt':
        merged = suite.directory / 'case-merge' / 'include'
        merged.mkdir(parents=True)
        (merged / 'xt_connmark.h').write_bytes(b'original')
        (merged / 'retained').write_bytes(b'keep')
        result = suite.check("local ok, err = pcall(cp,'case-source','case-merge',"
                             "{recursive=true,overwrite=true}); print(ok and 'copied' or err)")
        if result.stdout.strip() == 'copied':
            for name, data in headers.items():
                assert (merged / name).read_bytes() == data
            for name in ('ABI', 'abi'):
                assert (merged / name / 'kind').read_text() == name
        else:
            diagnostic = result.stdout.lower()
            assert 'case' in diagnostic and 'sensitiv' in diagnostic and 'include' in diagnostic, diagnostic
            assert {p.name for p in merged.iterdir() if p.name.lower() == 'xt_connmark.h'} == {'xt_connmark.h'}
            assert (merged / 'xt_connmark.h').read_bytes() == b'original'
        assert (merged / 'retained').read_bytes() == b'keep'


def check_quick_progress(suite):
    tree = suite.directory / 'progress-source'
    (tree / 'nested').mkdir(parents=True)
    payload = bytes(range(256))
    (tree / 'data').write_bytes(payload)
    (tree / 'nested/tail').write_bytes(b'tail')
    (tree / 'empty').mkdir()
    remove_tree = suite.directory / 'delete-test'
    remove_tree.mkdir()
    try:
        # The interactive deletion traversal must treat a directory link as a leaf.
        os.symlink(tree, remove_tree / 'link', target_is_directory=True)
    except OSError as error:
        if error.winerror not in (5, 50, 1314):
            raise
    code = '''
        assert(cp('progress-source/data', 'single-result'))
        assert(cp('progress-source', 'tree-result', {recursive=true}))
        assert(cp('progress-source/empty', 'empty-result', {recursive=true}))
        local ok, err = pcall(cp, 'progress-source/data', 'single-result')
        assert(not ok and type(err)=='string' and #err>0)
        show(ls('-l', '--total-size', 'progress-source'))
        assert(rm('empty-result', {recursive=true}))
        assert(not pcall(rm, 'tree-result/.', {recursive=true}))
        assert(rm('delete-test', {recursive=true}))
        print('finished')
    '''
    trace = terminal_run(suite, code, suite.directory)
    assert b'finished' in trace.raw, trace.raw
    assert all(label not in trace.raw for label in (b'Copying', b'Scanning', b'Deleted')), trace.raw
    assert (suite.directory / 'single-result').read_bytes() == payload
    assert (suite.directory / 'tree-result/data').read_bytes() == payload
    assert (suite.directory / 'tree-result/nested/tail').read_bytes() == b'tail'
    assert (suite.directory / 'tree-result/empty').is_dir()
    assert (tree / 'data').read_bytes() == payload
    assert not (suite.directory / 'empty-result').exists() and not remove_tree.exists()


def check_slow_progress(suite):
    from tui_cursor import Pseudoconsole

    fixture = suite.directory / 'browser-copy'
    source, destination = fixture / 'source', fixture / 'destination'
    (source / 'folder').mkdir(parents=True)
    destination.mkdir()
    (source / 'file').write_bytes(b'file data')
    # Reuse one tree for scans, browser copy/delete and recursive shell deletion.
    # File count makes the operations observable without a large disk fixture.
    for index in range(1024):
        child = source / 'folder' / str(index)
        child.mkdir()
        (child / 'data').write_bytes(b'abc')
        (child / 'empty').touch()

    scan = "show(ls('-l','--total-size','source'))"
    captured = suite.check(scan, cwd=fixture)
    assert 'folder' in captured.stdout and not captured.stderr and 'Scanning' not in captured.stdout
    structured = suite.check("local rows=ls('--total-size','-d','source/folder'):collect(); "
                             "assert(#rows==1 and rows[1].size==3072)", '', cwd=fixture)
    assert not structured.stderr

    trace = terminal_run(suite, f"local t = os.clock(); {scan}; print('elapsed', os.clock()-t)", fixture)
    lines = [''.join(row).rstrip() for row in trace.cells]
    assert any('folder' in line for line in lines), lines
    # Count only the operation itself. A particularly fast filesystem can finish
    # a fixture before the 250 ms delay expires, which correctly produces no row.
    seconds = float(next(line.split()[-1] for line in lines if line.startswith('elapsed')))
    if seconds > .4:
        assert re.search(rb'Scanning [\d,]+ entr', trace.raw), bytes(trace.raw[-1500:])
    assert all('Scanning' not in line for line in lines), lines

    terminal = Pseudoconsole(suite.executable, "show(ls('--tui','source'))", 100, 24, cwd=fixture)
    transcript = bytearray()

    def wait_for(text):
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline and text not in transcript:
            transcript.extend(terminal.receive())
            assert terminal.poll() is None, (terminal.poll(), bytes(transcript[-1500:]))
        assert text in transcript, bytes(transcript[-1500:])

    try:
        wait_for(b'folder/')
        # Select both items, go to their parent, open destination, then paste.
        transcript.clear()
        started = time.monotonic()
        terminal.send(b'ahglp')
        wait_for(b'copied 2 item(s)')
        if time.monotonic() - started > .5:
            assert b'Copying' in transcript, 'browser copy never displayed progress'
            assert re.search(rb'\d[\d.,]* (?:B|KiB)\b|Copied [\d,]+ entr', transcript), (
                'expected a byte or entry count while copying small files', bytes(transcript[-2000:]))
        assert (destination / 'file').read_bytes() == b'file data'
        assert len(list((destination / 'folder').iterdir())) == 1024
        assert (destination / 'folder/1023/data').read_bytes() == b'abc'
        terminal.send(b'uax')
        wait_for(b'delete 2 selected item(s)?')
        transcript.clear()
        start = time.monotonic()
        terminal.send(b'y')
        wait_for(b'deleted 2 item(s)')
        if time.monotonic() - start > .5:
            assert re.search(rb'[12]/2 Deleted [\d,]+ entr', transcript), bytes(transcript[-2000:])
        terminal.send(b'q')
        deadline = time.monotonic() + 5
        while terminal.poll() is None and time.monotonic() < deadline:
            terminal.receive()
        assert terminal.poll() == 0, 'browser did not exit normally after copying'
    finally:
        terminal.close()
    assert not list(destination.iterdir())
    trace = terminal_run(suite, "local t = os.clock(); assert(rm('source/folder',{recursive=true})); "
                         "print('elapsed', os.clock()-t)", fixture)
    lines = [''.join(row).rstrip() for row in trace.cells]
    seconds = float(next(line.split()[-1] for line in lines if line.startswith('elapsed')))
    if seconds > .4:
        assert 'Deleted 3,073 entries' in lines, lines
    assert not (source / 'folder').exists() and (source / 'file').read_bytes() == b'file data'


def check_large_child_progress(suite, size_mib):
    # Opt in because observable intermediate frames need a copy that lasts
    # beyond the display delay, and transfer speeds vary between machines.
    source = suite.directory / 'single-child'
    source.mkdir()
    data = bytes(range(256)) * 4096
    with (source / 'large.bin').open('wb') as output:
        for _ in range(size_mib):
            output.write(data)
    trace = terminal_run(suite, "local t=os.clock(); assert(cp('single-child','large-backup',{recursive=true})); "
                         "print('elapsed',os.clock()-t)", suite.directory)
    assert filecmp.cmp(source / 'large.bin', suite.directory / 'large-backup/large.bin', shallow=False)
    percentages = [int(value) for value in re.findall(rb'(\d+)%', trace.raw)]
    lines = [''.join(row).rstrip() for row in trace.cells]
    seconds = float(next(line.split()[-1] for line in lines if line.startswith('elapsed')))
    # Cached or offloaded copies can finish even a GiB before the initial
    # delay. Only require an intermediate frame if there was time to show one.
    if seconds < .5:
        if percentages:
            assert percentages[-1] == 100, percentages
        return
    # Entry-based progress in this tree can only be 0%, 50% or 100%.
    assert any(0 < value < 100 and value != 50 for value in percentages), (
        'expected progress during the only file; increase --large-copy-mib for a fast disk', percentages)
    assert percentages[-1] == 100, percentages


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    parser.add_argument('--large-copy-mib', type=int, default=0,
                        help='also verify progress inside one large file on Windows, e.g. 1024 MiB')
    arguments = parser.parse_args()
    if arguments.large_copy_mib < 0:
        parser.error('--large-copy-mib must be nonnegative')
    executable = arguments.exe.resolve()
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='filesystem-test-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        suite = Statements(executable, directory)
        check_home_paths(suite)
        suite.check('''for _, name in ipairs({'mkdir','touch','cp','mv','rm','stat','exists'}) do
            assert(type(_G[name]) == 'function' and lush[name] == _G[name]) end
            assert(type(path) == 'table' and lush.path == path)''', '')

        suite.check("assert(mkdir('nested/한글')); assert(mkdir('nested/한글')); "
                    "assert(stat('nested').type == 'dir'); "
                    "assert(not pcall(mkdir,'missing/child',{parents=false})); "
                    "assert(not exists('missing')); "
                    "assert(mkdir('one-level',{parents=false}))", '')
        (directory / 'parent-file').write_text('preserve', encoding='utf-8')
        suite.check("assert(not pcall(mkdir,'parent-file/child')); "
                    "assert(not pcall(mkdir,'parent-file'))", '')
        assert (directory / 'parent-file').read_text() == 'preserve'

        suite.check("assert(touch('new.txt')); assert(stat('new.txt').size == 0); "
                    "assert(type(stat('new.txt').modified) == 'number')", '')
        original = b'contents\x00remain\r\n\xff'
        source = directory / 'source [1] 한글.bin'
        source.write_bytes(original)
        os.utime(source, (1, 1))
        suite.check("assert(touch('source [1] 한글.bin')); "
                    "assert(stat('source [1] 한글.bin').modified > 1)", '')
        assert source.read_bytes() == original, 'touch truncated existing data'
        assert source.stat().st_mtime > 1, 'touch did not update modification time'
        suite.check("local s=stat('source [1] 한글.bin'); "
                    "assert(s.path=='source [1] 한글.bin' and s.name==s.path and s.type=='file'); "
                    f"assert(s.size=={len(original)}); "
                    "assert(not exists('absent') and not path.exists('absent')); "
                    "assert(not pcall(stat,'absent'))", '')

        result = suite.check("assert(cp('source [1] 한글.bin','copied.bin'))", '')
        assert result.stderr == '', 'redirected file copies should be quiet'
        assert (directory / 'copied.bin').read_bytes() == original
        (directory / 'copied.bin').write_bytes(b'destination survives')
        suite.check("assert(not pcall(cp,'source [1] 한글.bin','copied.bin'))", '')
        assert (directory / 'copied.bin').read_bytes() == b'destination survives'
        suite.check("assert(cp('source [1] 한글.bin','copied.bin',{overwrite=true})); "
                    "assert(not pcall(cp,'source [1] 한글.bin','source [1] 한글.bin',{overwrite=true})); "
                    "assert(not pcall(cp,'absent','absent-copy'))", '')
        assert source.read_bytes() == original and (directory / 'copied.bin').read_bytes() == original
        suite.check("assert(mkdir('exact-directory')); "
                    "assert(not pcall(cp,'copied.bin','exact-directory')); "
                    "assert(not pcall(cp,'copied.bin','exact-directory',{overwrite=true}))", '')
        assert not (directory / 'exact-directory/copied.bin').exists(), 'cp appended the source basename'

        tree = directory / 'tree'
        (tree / 'sub').mkdir(parents=True)
        (tree / 'sub/data.txt').write_bytes(original)
        result = suite.check("assert(not pcall(cp,'tree','tree-copy')); assert(not exists('tree-copy')); "
                             "assert(cp('tree','tree-copy',{recursive=true})); "
                             "assert(not pcall(cp,'tree','tree-copy',{recursive=true})); "
                             "assert(not pcall(cp,'tree','tree/inside',{recursive=true}))", '')
        assert result.stderr == '', 'redirected recursive copies should be quiet'
        assert (directory / 'tree-copy/sub/data.txt').read_bytes() == original
        (directory / 'tree-copy/retained.txt').write_text('retain', encoding='utf-8')
        (tree / 'new.txt').write_text('new', encoding='utf-8')
        suite.check("assert(cp('tree','tree-copy',{recursive=true,overwrite=true}))", '')
        assert (directory / 'tree-copy/new.txt').read_text() == 'new'
        assert (directory / 'tree-copy/retained.txt').read_text() == 'retain'

        suite.check("assert(mv('copied.bin','moved.bin')); assert(not exists('copied.bin')); "
                    "assert(exists('moved.bin'))", '')
        (directory / 'move-destination.bin').write_bytes(b'do not replace')
        suite.check("assert(not pcall(mv,'moved.bin','move-destination.bin'))", '')
        assert (directory / 'moved.bin').read_bytes() == original
        assert (directory / 'move-destination.bin').read_bytes() == b'do not replace'
        suite.check("assert(mv('moved.bin','move-destination.bin',{overwrite=true})); "
                    "assert(not exists('moved.bin')); "
                    "assert(not pcall(mv,'move-destination.bin','exact-directory')); "
                    "assert(mv('tree-copy','renamed-tree'))", '')
        assert (directory / 'move-destination.bin').read_bytes() == original
        assert (directory / 'renamed-tree/sub/data.txt').read_bytes() == original
        assert not (directory / 'exact-directory/move-destination.bin').exists()

        suite.check("assert(not pcall(rm,'renamed-tree')); "
                    "assert(not pcall(rm,'renamed-tree',{force=true})); "
                    "assert(exists('renamed-tree/sub/data.txt')); "
                    "assert(rm('one-level')); assert(not exists('one-level')); "
                    "assert(not pcall(rm,'absent')); assert(rm('absent',{force=true})); "
                    "assert(not pcall(rm,'absent',{recursive=true})); "
                    "assert(rm('absent',{recursive=true,force=true})); "
                    "assert(rm('renamed-tree',{recursive=true})); assert(not exists('renamed-tree'))", '')
        assert (tree / 'sub/data.txt').read_bytes() == original, 'rm affected the source tree'

        check_case_sensitive_copy(suite)
        if os.name == 'nt':
            check_quick_progress(suite)
            check_slow_progress(suite)
            if arguments.large_copy_mib:
                check_large_child_progress(suite, arguments.large_copy_mib)

        suite.check("assert(path.basename('alpha/beta.tar.gz')=='beta.tar.gz'); "
                    "assert(path.dirname('alpha/beta.tar.gz')=='alpha'); "
                    "assert(path.stem('alpha/beta.tar.gz')=='beta.tar'); "
                    "assert(path.extension('alpha/beta.tar.gz')=='.gz'); "
                    "assert(path.extension('no-extension')==''); "
                    "assert(path.normalize('alpha/../beta')=='beta'); "
                    "assert(path.join('alpha','..','beta')=='beta')", '')
        absolute_child = str(directory / 'absolute-child')
        suite.check(f"assert(path.join('discarded', {lua_string(absolute_child)}) == "
                    f"{lua_string(os.path.normpath(absolute_child))})", '')
        if os.name == 'nt':
            verbatim = '\\\\?\\' + str(directory)
            suite.check(f"local base = {lua_string(verbatim)}; " + r"""
                local child = path.join('discarded', base, 'tree', 'sub/data.txt')
                assert(child == base .. [[\tree\sub\data.txt]] and exists(child), child)
                local share = [[\\?\UNC\server\share]]
                assert(path.join(share, 'a/b', '/root/leaf') == share .. [[\root\leaf]])
                local explicit = [[\\?\C:\exact/bytes]]
                assert(path.join(base, explicit) == explicit)
                local device = '//?/C:/ordinary/../safe'
                assert(path.join(base, device) == [[\\.\C:\safe]])
                """, '')
        result = suite.check("print(path.expand('.'))")
        assert Path(result.stdout.strip()).is_absolute()
        assert Path(result.stdout.strip()).resolve() == directory.resolve()
        environment = dict(os.environ, LUSH_FILESYSTEM_EXPAND=str(directory / 'expanded'))
        variable = '%LUSH_FILESYSTEM_EXPAND%' if os.name == 'nt' else '${LUSH_FILESYSTEM_EXPAND}'
        result = suite.check(f"print(path.expand({lua_string(variable)}))", environment=environment)
        assert Path(result.stdout.strip()).resolve() == directory / 'expanded'

        suite.check('''local checks = {
            function() mkdir('invalid-options',{parents=1}) end,
            function() mkdir('invalid-options',{unknown=true}) end,
            function() cp('source [1] 한글.bin','invalid-copy',{overwrite='yes'}) end,
            function() mv('source [1] 한글.bin','invalid-move',{recursive=true}) end,
            function() rm('source [1] 한글.bin',{force=1}) end,
            function() stat('source [1] 한글.bin',{}) end,
            function() touch('invalid'..string.char(0)..'suffix') end,
            function() exists('invalid'..string.char(0)..'suffix') end,
            function() path.join('valid',12) end,
            function() path.normalize(false) end,
            function() touch('') end,
        }
        for _, check in ipairs(checks) do local ok,message=pcall(check);
            assert(not ok and type(message)=='string' and #message>0) end''', '')
        assert not (directory / 'invalid-options').exists() and not (directory / 'invalid-copy').exists()
        assert not (directory / 'invalid-move').exists() and source.read_bytes() == original

        links_exercised = False
        try:
            os.symlink('tree', directory / 'tree-link', target_is_directory=True)
        except OSError as error:
            if os.name != 'nt' or error.winerror not in (5, 50, 1314):
                raise
        else:
            links_exercised = True
            suite.check("assert(stat('tree-link').type=='dir'); "
                        "assert(stat('tree-link',false).type=='symlink'); "
                        "assert(cp('tree-link','copied-link')); "
                        "assert(stat('copied-link',false).type=='symlink'); "
                        "assert(rm('tree-link',{recursive=true})); "
                        "assert(not exists('tree-link') and exists('tree/sub/data.txt'))", '')
            os.symlink('missing-target', directory / 'dangling')
            suite.check("assert(exists('dangling') and path.exists('dangling')); "
                        "assert(not pcall(stat,'dangling')); "
                        "assert(stat('dangling',false).type=='symlink'); "
                        "assert(rm('dangling'))", '')
            assert (tree / 'sub/data.txt').read_bytes() == original

        suite.check("for i=1,300 do assert(exists('source [1] 한글.bin')); "
                    "assert(stat('source [1] 한글.bin').type=='file'); "
                    "assert(path.join('alpha','..','beta')=='beta') end", '')
        print(f'filesystem checks passed: {suite.checks} subprocess cases '
              f'(symlinks {"exercised" if links_exercised else "unavailable"})')


if __name__ == '__main__':
    main()
