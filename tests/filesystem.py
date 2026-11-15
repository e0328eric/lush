#!/usr/bin/env python3
"""Exercise filesystem builtins in an isolated build directory.

Run: python tests/filesystem.py --exe build/lush.exe
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import tempfile

from integration import ROOT, Suite, lua_string


class Statements(Suite):
    def check(self, source, expected=None, **options):
        # A successful assert(...) is itself an expression that the REPL displays.
        return super().check('do\n' + source + '\nend', expected, **options)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    arguments = parser.parse_args()
    executable = arguments.exe.resolve()
    (ROOT / 'build').mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='filesystem-test-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        suite = Statements(executable, directory)
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

        suite.check("assert(cp('source [1] 한글.bin','copied.bin'))", '')
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
        suite.check("assert(not pcall(cp,'tree','tree-copy')); assert(not exists('tree-copy')); "
                    "assert(cp('tree','tree-copy',{recursive=true})); "
                    "assert(not pcall(cp,'tree','tree-copy',{recursive=true})); "
                    "assert(not pcall(cp,'tree','tree/inside',{recursive=true}))", '')
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
