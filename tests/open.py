#!/usr/bin/env python3
"""Test cat bytes and Windows opener dispatch without opening user applications.

Run: python tests/open.py --exe build/lush.exe
All fixtures stay in build/. The native probe substitutes the OS procedure;
the only real Windows handoff uses a missing file with error dialogs disabled.
No registry entries, default associations or existing user files are changed.
"""
from __future__ import annotations

import argparse
import os
from pathlib import Path
import subprocess
import tempfile

from integration import ROOT, Suite, lua_string


def check(executable, compiler):
    with tempfile.TemporaryDirectory(prefix='open-test-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        suite = Suite(executable, directory)
        contents = bytes(range(256)) + b'\r\n\x00\xff\n'
        source = directory / 'literal ; $ name 한글.bin'
        source.write_bytes(contents)
        empty = directory / 'empty'
        empty.write_bytes(b'')
        suite.check('assert(type(open)=="function" and open==lush.open); '
                    'assert(cat==lush.cat and cat==lush.read and cat~=open); '
                    'assert(type(io.open)=="function")', '')
        for function in ('cat', 'lush.cat', 'lush.read'):
            result = suite.run(source=f'local _=io.write({function}({lua_string(source)}))', binary=True)
            assert result.stdout == contents and not result.stderr, (function, result)
        suite.check(f'local _=assert(cat({lua_string(empty)})=="")', '')
        missing = directory / 'missing directory' / 'never exists 한글.txt'
        suite.check(f'local ok,message=pcall(cat,{lua_string(missing)}); '
                    'assert(not ok and type(message)=="string" and #message>0)', '')

        # Intercept only this subprocess's native table to verify the public
        # wrapper passes one exact string and propagates native outcomes.
        targets = ['https://example.invalid/a path?q=x&literal=%22#fragment',
                   str(source), str(directory), 'quoted "value"; echo $HOME | literal',
                   '한글 😀 e\u0301']
        literals = ','.join(lua_string(target) for target in targets)
        suite.check('local original=_lush.open; local calls={}; '
                    '_lush.open=function(target) calls[#calls+1]=target; return true end; '
                    f'local targets={{{literals}}}; '
                    'for _,target in ipairs(targets) do assert(open(target)==true); '
                    'assert(calls[#calls]==target) end; '
                    'assert(#calls==#targets); '
                    'for _,target in ipairs{false,17,{},function() end,"","nul\\0suffix"} do '
                    'local ok,message=pcall(open,target); assert(not ok and type(message)=="string") end; '
                    'assert(not pcall(open)); assert(#calls==#targets); '
                    '_lush.open=function() return nil,"native-open-test-failure" end; '
                    'local ok,message=pcall(open,"literal"); '
                    'assert(not ok and message:find("native-open-test-failure",1,true)); '
                    '_lush.open=original', '')

        # Invalid arguments are rejected before reaching any OS API.
        suite.check('for _,target in ipairs{false,42,{},"","nul\\0suffix",string.char(255)} do '
                    'local value,message=_lush.open(target); '
                    'assert(value==nil and type(message)=="string" and #message>0) end', '')
        if os.name == 'nt':
            suite.check(f'local ok,message=pcall(open,{lua_string(missing)}); '
                        'assert(not ok and type(message)=="string" and #message>0)', '', timeout=10)
            assert compiler.is_file(), f'Glosso compiler not found: {compiler}'
            probe = directory / 'opener-probe.exe'
            environment = dict(os.environ)
            resources = ROOT / 'build/lua-resources'
            if (resources / 'thirdparty/lua/src/glosso_lua.h').is_file():
                environment['GLOSSO_LIB_DIR'] = str(resources)
            compiled = subprocess.run([str(compiler), 'compile', '--std', str(ROOT.parent / 'glosso/std'),
                        '--cache-dir', str(ROOT / 'build/open-test-cache'), str(ROOT / 'tests/opener.glo'),
                        '-o', str(probe), '--color', 'never'], cwd=ROOT, env=environment,
                        capture_output=True, text=True, encoding='utf-8', timeout=60)
            assert compiled.returncode == 0, (compiled.stdout, compiled.stderr)
            result = subprocess.run([str(probe)], cwd=directory, capture_output=True,
                                    text=True, encoding='utf-8', timeout=10)
            assert result.returncode == 0, (result.returncode, result.stdout, result.stderr)
            print(result.stdout.strip())
        print(f'open/cat checks passed: {suite.checks} subprocess cases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    parser.add_argument('--compiler', type=Path, default=ROOT.parent / 'glosso/build/bin' /
                        ('glosso.exe' if os.name == 'nt' else 'glosso'))
    arguments = parser.parse_args()
    check(arguments.exe.resolve(strict=True), arguments.compiler.resolve())


if __name__ == '__main__': main()
