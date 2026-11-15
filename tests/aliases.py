#!/usr/bin/env python3
"""Exercise aliases with isolated Python commands and temporary configuration.

Run: python tests/aliases.py --exe build/lush.exe
All fixture files stay in build/. No editor, WSL instance, clipboard service or
other program from the example aliases is launched.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import sys
import tempfile

from integration import ROOT, Suite, lua_string


class Statements(Suite):
    def check(self, source, expected='', **options):
        return super().check('do\n' + source + '\nend', expected, **options)


FIXTURE = '''import json,pathlib,sys
mode=sys.argv[1]
if mode=='argv': print(json.dumps(sys.argv[2:]))
elif mode=='copy': sys.stdout.buffer.write(sys.stdin.buffer.read())
elif mode=='save': pathlib.Path(sys.argv[2]).write_bytes(sys.stdin.buffer.read())
elif mode=='touch': pathlib.Path(sys.argv[2]).write_text('launched',encoding='utf-8')
elif mode=='fail': sys.stderr.write('alias fixture failure'); sys.exit(7)
else: raise RuntimeError(mode)
'''


def check(executable):
    with tempfile.TemporaryDirectory(prefix='aliases-test-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        suite = Statements(executable, directory)
        regression = suite.run(ROOT / 'tests/aliases.lua')
        assert 'aliases:' in regression.stdout and 'checks passed' in regression.stdout, regression
        fixture = directory / 'fixture with spaces 한글.py'
        fixture.write_text(FIXTURE, encoding='utf-8')
        prefix = '{' + lua_string(sys.executable) + ',' + lua_string(fixture) + ','
        registration = lambda name, mode, extra='': ('alias(' + lua_string(name) + ',' + prefix +
                                                    lua_string(mode) + extra + '}); ')
        args = ['space in argument', '"quote"', "single'quote", '$HOME; & | > literal', '한글 😀', '', '17']
        arguments = ','.join(lua_string(value) for value in args[:-1]) + ',17'
        result = suite.check(registration('fixture_alias', 'argv', ',"fixed prefix"') +
                             f'local result=capture(fixture_alias({arguments})); assert(result.ok,result.stderr); io.write(result.stdout)',
                             expected=None)
        assert json.loads(result.stdout) == ['fixed prefix', *args], result
        marker = directory / 'launched marker.txt'
        suite.check(registration('lazy_alias', 'touch', ',' + lua_string(marker)) +
                    'local plan=lazy_alias(); assert(not exists(' + lua_string(marker) + ')); '
                    'capture(plan):check(); assert(exists(' + lua_string(marker) + '))')
        assert marker.read_text(encoding='utf-8') == 'launched'
        suite.check(registration('copy_alias', 'copy') +
                    'local input="raw\\0bytes\\r\\n한글"; '
                    'local result=(copy_alias() | copy_alias()):capture(input):check(); '
                    'assert(result.stdout==input and #result.statuses==2 and '
                    'result.statuses[1]==0 and result.statuses[2]==0)')
        sink = directory / 'clipboard-style fixture.bin'
        suite.check(registration('clipboard_alias', 'save', ',' + lua_string(sink)) +
                    'local input="piped\\0bytes\\r\\n한글"; '
                    'local result=run(input | clipboard_alias()):check(); assert(result.code==0)')
        assert sink.read_bytes() == 'piped\0bytes\r\n한글'.encode('utf-8')
        suite.check(registration('failure_alias', 'fail') +
                    'local result=capture(failure_alias()); '
                    'assert(not result.ok and result.code==7 and result.stderr=="alias fixture failure"); '
                    'assert(not pcall(function() result:check() end))', status=7)
        suite.check('_lush.execute=function() error("example executed a process") end; '
                    'source(' + lua_string(ROOT / 'examples/aliases.lua') + '); '
                    'assert(#aliases()==19 and s==ls and help(s)==help(ls)); '
                    'assert(help("s"):find("ls",1,true)); '
                    'local flags=l("literal directory").fls_arguments; '
                    'assert(#flags==2 and flags[1]=="-al" and flags[2]=="literal directory"); '
                    'local expected={v={"nvim"},h={"hx"},lg={"lazygit"},dyt={"yt-dlp"},'
                    'getmusic={"yt-dlp","-x","--audio-format","m4a"},pbcopy={"win32yank.exe","-i"},'
                    'archlinux={"wsl.exe","-d","archlinux","--cd","~","-u","almagest"}}; '
                    'for name,prefix in pairs(expected) do local argv=_G[name]("extra").commands[1]; '
                    'assert(#argv==#prefix+1 and argv[#argv]=="extra"); '
                    'for i,value in ipairs(prefix) do assert(argv[i]==value) end end; '
                    'local expected_paths={hakwon="C:/Users/almag/pCloud/TeX_Documents/Hakwon",'
                    'minireport="C:/Users/almag/pCloud/TeX_Documents/Mini_Report",'
                    'notetaking="C:/Users/almag/pCloud/TeX_Documents/NoteTaking",'
                    'homework="C:/Users/almag/pCloud/TeX_Documents/Homework",'
                    'teachingf="C:/Users/almag/pCloud/TeX_Documents/TF",'
                    'seminar="C:/Users/almag/pCloud/TeX_Documents/Seminar",'
                    'papers="C:/Users/almag/pCloud/TeX_Documents/Papers",'
                    'kindergarten="C:/Users/almag/pCloud/TeX_Documents/Kindergarten",'
                    'vimconfig="C:/Users/almag/AppData/Local/nvim",flowconfig="C:/Users/almag/AppData/Roaming/flow"}; '
                    'local visited; cd=function(value) visited=value end; '
                    'for name,value in pairs(expected_paths) do visited=nil; _G[name](); assert(visited==value) end')

        # Execute the shipped default init in a throwaway config directory. Its
        # optional sibling aliases.lua is normal trusted configuration source.
        config = directory / 'init.lua'
        aliases_file = directory / 'aliases.lua'
        config.write_text('source(' + lua_string(ROOT / 'src/default_init.lua') + ')\n', encoding='utf-8')
        result = suite.run('--config', config, source='local _=assert(configured_alias==nil)', no_config=False)
        assert not result.stdout, result
        aliases_file.write_text('alias("configured_alias",function() return 41 end)\n', encoding='utf-8')
        suite.run('--config', config, source='local _=assert(configured_alias()==41)', no_config=False)
        aliases_file.write_text('alias("configured_alias",function() return 42 end)\n', encoding='utf-8')
        suite.run('--config', config, source='local _=assert(configured_alias()==42)', no_config=False)
        environment = dict(os.environ, LUSH_CONFIG=str(config))
        suite.check('assert(configured_alias==nil)', environment=environment)
        aliases_file.write_text('alias("configured_alias", false)\n', encoding='utf-8')
        failed = suite.run('--config', config, source='print("unreachable")', no_config=False, status=None)
        assert failed.returncode != 0 and failed.stderr and 'unreachable' not in failed.stdout, failed

        print(f'aliases integration checks passed: {suite.checks} subprocess cases')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build' / ('lush.exe' if os.name == 'nt' else 'lush'))
    arguments = parser.parse_args()
    check(arguments.exe.resolve(strict=True))


if __name__ == '__main__': main()
