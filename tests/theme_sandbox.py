#!/usr/bin/env python3
"""Adversarial theme isolation checks; all files/process markers stay in build/.

Run: python tests/theme_sandbox.py --exe build/lush.exe
Every adversarial case runs in a fresh subprocess with a finite timeout.
"""
import argparse
import os
from pathlib import Path
import secrets
import shlex
import subprocess
import sys
import tempfile

from integration import ROOT, Suite, lua_string


def prompt(text='safe> '):
    return 'local t=lush.theme\nreturn t.prompt{input={t.text(' + lua_string(text) + ')}}\n'


def command_for(marker):
    args = [sys.executable, '-c', "import pathlib,sys; pathlib.Path(sys.argv[1]).write_text('created',encoding='utf-8')", str(marker)]
    return subprocess.list2cmdline(args) if os.name == 'nt' else shlex.join(args)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='theme-sandbox-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        themes = directory / 'themes'
        themes.mkdir()
        init = directory / 'init.lua'
        marker = directory / 'unauthorized-write.txt'
        process_marker = directory / 'unauthorized-process.txt'
        secret = 'private-fixture-' + secrets.token_hex(12)
        secret_file = directory / 'secret.txt'
        secret_file.write_text(secret, encoding='utf-8')
        suite = Suite(args.exe.resolve(strict=True), directory)

        def run(name, contents, verify, prelude='', timeout=3):
            (themes / (name + '.lua')).write_text(contents, encoding='utf-8')
            init.write_text('lush.config.theme=nil\nlush.config.theme_options={icons=false,git=false,time=false}\n' +
                            f'SANDBOX_HOST_SECRET={lua_string(secret)}\n' + prelude + '\n', encoding='utf-8')
            code = 'do local value,message=lush.theme.load(' + lua_string(name) + '); ' + verify + ' end'
            result = suite.run('--config', init, source=code, no_config=False, timeout=timeout)
            assert not marker.exists(), name + ' wrote a file through the sandbox'
            assert not process_marker.exists(), name + ' launched a process through the sandbox'
            return result

        denied = ('assert(value==nil and type(message)=="string" and #message>0); '
                  f'assert(not message:find({lua_string(secret)},1,true)); '
                  'assert(not message:find(string.char(27),1,true))')
        run('safe-api', '''local t=lush.theme
assert(_G==_ENV and SANDBOX_HOST_SECRET==nil)
for _,name in ipairs{'os','io','package','debug','require','source','cmd','run','capture','cat','open','alias','aliases','env','_lush',
 'load','loadfile','dofile','getmetatable','setmetatable','rawset','pcall','xpcall','coroutine','collectgarbage','print','warn'} do
 assert(_G[name]==nil,name)
end
assert(lush.theme.load==nil and lush.write==nil and lush.read==nil and lush.cat==nil and lush.open==nil and lush.cmd==nil)
assert(lush.alias==nil and lush.aliases==nil)
for _,name in ipairs{'match','gmatch','gsub','dump'} do assert(string[name]==nil and ('text')[name]==nil,name) end
assert(string.find('a.b','.')==2 and ('a.b'):find('.')==2 and string.find('abc','.')==nil)
assert(string.sub('abc',2)=='bc' and ('ab'):upper()=='AB' and ('x'):rep(3)=='xxx')
return t.prompt{input={t.text('safe> ')}}
''', 'assert(value.kind=="prompt" and lush.theme.render(value,{cwd="/test"}).input=="safe> ")')

        attacks = {
            'io-read': f'local f=assert(io.open({lua_string(secret_file)},"rb")); error(f:read("*a"))',
            'shell-read': f'error(cat({lua_string(secret_file)}))',
            'shell-open': f'open({lua_string(secret_file)})',
            'io-write': f'local f=assert(io.open({lua_string(marker)},"wb")); f:write("escape"); f:close()',
            'lush-write': f'lush.write({lua_string(marker)},"escape")',
            'os-process': f'os.execute({lua_string(command_for(process_marker))})',
            'shell-process': f'run({lua_string(sys.executable)},"-c","pass")',
            'io-popen': f'io.popen({lua_string(command_for(process_marker))}):close()',
            'environment': 'error(os.getenv("LUSH_SANDBOX_SECRET"))',
            'dependency': 'require("sandbox_private_dependency")',
            'package-escape': 'return package.loaded._G',
            'debug-escape': 'return debug.getregistry()',
            'native-escape': f'_lush.write({lua_string(marker)},"escape")',
            'source-escape': f'source({lua_string(secret_file)})',
            'nested-loader': 'return lush.theme.load("safe-api")',
            'dynamic-load': 'return load("return _G")()',
            'file-load': f'return loadfile({lua_string(secret_file)})()',
            'metatable': 'return setmetatable({kind="prompt",rows={},input={}},{__index=function() error("callback") end})',
            'error-function': 'error(function() error("error callback invoked") end)',
            'error-controls': 'error("bad"..string.char(27).."[2J")',
            'returned-function': 'return {kind="prompt",rows={},input={},extra=function() return _G end}',
            'returned-cycle': 'local p={kind="prompt",rows={},input={}}; p.extra=p; return p',
            'returned-nan': 'return {kind="prompt",rows={},input={},extra=0/0}',
            'returned-infinity': 'return {kind="prompt",rows={},input={},extra=1/0}',
            'returned-table-key': 'return {kind="prompt",rows={},input={},[{}]="object key"}',
            'pattern-method': "return ('a'):rep(128):match('^'..('a*'):rep(16)..'b$')",
            'pattern-table': "return string.gsub(('a'):rep(128),('a*'):rep(16)..'b','x')",
            'pcall-loop': 'while true do pcall(function() while true do end end) end',
            'coroutine-loop': 'coroutine.resume(coroutine.create(function() while true do end end))',
            'cpu-loop': 'while true do end',
            'cpu-recursion': 'local f; f=function() return f()+1 end; return f()',
            'sort-callback-budget': 'local x={}; for i=1,100 do x[i]=i end; table.sort(x,function() while true do end end)',
            'trusted-api-budget': "local x=('a'):rep(16000); while true do lush.theme.sanitize(x) end",
            'large-rep': "return ('x'):rep(1000000000)",
            'large-format': "return string.format('%1000000000s','x')",
            'large-unpack': 'return table.unpack({},1,1000000000)',
            'large-move': 'return table.move({},1,1000000000,1,{})',
            'memory-loop': "local value='x'; while true do value=value..value end",
            'deep-result': 'local p={kind="prompt",rows={},input={}}; local q=p; for i=1,100 do q.extra={}; q=q.extra end; return p',
            'large-result': 'local p={kind="prompt",rows={},input={}}; p.extra={}; for i=1,10000 do p.extra[i]=i end; return p',
        }
        dependency = (f'package.preload.sandbox_private_dependency=function() lush.write({lua_string(marker)},"dependency"); '
                      f'return {lua_string(secret)} end\n')
        for name, contents in attacks.items():
            run(name, contents, denied, prelude=dependency)
        run('source-limit', '--' + 'x' * (256 * 1024) + '\n' + prompt(), denied)

        # The private VM must not inherit host globals, functions or string methods.
        prelude = ('host_escape_calls=0; string.sandbox_host_escape=function() host_escape_calls=host_escape_calls+1; return _G end; '
                   'math.sandbox_host_escape=string.sandbox_host_escape; table.sandbox_host_escape=string.sandbox_host_escape; '
                   'math.randomseed(12345); expected_random=math.random(); math.randomseed(12345)')
        run('private-libs', '''assert(SANDBOX_HOST_SECRET==nil)
assert(string.sandbox_host_escape==nil and ('x').sandbox_host_escape==nil)
assert(math.sandbox_host_escape==nil and table.sandbox_host_escape==nil)
_G.sandbox_private_global='guest'; math.sandbox_private='guest'; string.sandbox_private='guest'; table.sandbox_private='guest'
math.randomseed(7)
''' + prompt(), 'assert(value.kind=="prompt" and host_escape_calls==0); '
            'assert(sandbox_private_global==nil and math.sandbox_private==nil and string.sandbox_private==nil and table.sandbox_private==nil); '
            'assert(type(string.sandbox_host_escape)=="function" and math.random()==expected_random)', prelude=prelude)
        run('primitive-helper', "local g=('x').sandbox_host_escape(); g.lush.write(" + lua_string(marker) + ',"escape")',
            denied + '; assert(host_escape_calls==0)', prelude=prelude)
        run('number-helper', 'local g=(0).sandbox_host_escape(); return g', denied +
            '; debug.setmetatable(0,saved_number_meta); assert(host_escape_calls==0)',
            prelude=prelude + '; saved_number_meta=debug.getmetatable(0); '
            'debug.setmetatable(0,{__index={sandbox_host_escape=string.sandbox_host_escape}})')

        mutation = '''local t=lush.theme
return function(context,options)
 context.cwd='guest'; context.nested.value='changed'; options.icons=false; options.extra.flag=false
 return t.prompt{input={t.text(context.nested.value)}}
end'''
        run('copies', mutation, 'assert(type(value)=="function"); '
            'local context={cwd="host",nested={value="original"}}; local options={icons=true,extra={flag=true}}; '
            'local result=value(context,options); assert(lush.theme.render(result,{cwd="/test"}).input=="changed"); '
            'assert(context.cwd=="host" and context.nested.value=="original" and options.icons and options.extra.flag)')
        run('output-copy', 'local t=lush.theme; local p=t.prompt{input={t.text("guest")}}; return function() return p end',
            'local a=value({},{}); a.input[1].value="host"; local b=value({},{}); '
            'assert(b.input[1].value=="guest" and not rawequal(a,b))')
        for name, argument in {
            'input-function': '{callback=function() host_calls=host_calls+1 end}',
            'input-userdata': '{handle=io.stdout}',
            'input-metatable': 'setmetatable({},{__index=function() host_calls=host_calls+1 end,__pairs=function() host_calls=host_calls+1 end,__tostring=function() host_calls=host_calls+1 end})',
            'input-cycle': '(function() local x={}; x.self=x; return x end)()',
            'input-deep': '(function() local x={}; local n=x; for i=1,100 do n.child={};n=n.child end; return x end)()',
            'input-large': '(function() local x={}; for i=1,10000 do x[i]=i end; return x end)()',
        }.items():
            run(name, 'return function() ' + prompt() + ' end',
                'assert(type(value)=="function"); local ok,msg=pcall(value,' + argument + ',{}); '
                'assert(not ok and type(msg)=="string" and host_calls==0)', prelude='host_calls=0')
        run('permanent-failure', '''local t=lush.theme; local calls=0
return function()
 calls=calls+1
 if calls==2 then error('builder failed') end
 return t.prompt{input={t.text('call'..calls)}}
end''', 'assert(value({},{}).input[1].value=="call1"); '
            'assert(not pcall(value,{},{})); assert(not pcall(value,{},{})); '
            'assert(type(os.execute)=="function" and 2+3==5)')
        run('builder-budget', 'return function() while true do end end',
            'assert(type(value)=="function"); local ok,msg=pcall(value,{},{}); '
            'assert(not ok and type(msg)=="string"); assert(not pcall(value,{},{}))')

        # Sandboxing files must not remove ordinary shell capabilities.
        host_marker = directory / 'host-process.txt'
        run('host-still-full', prompt(), 'assert(value.kind=="prompt"); '
            'assert(type(os.execute)=="function" and type(io.open)=="function" and type(require)=="function" and type(debug.getregistry)=="function"); '
            'assert(require("math")==math); '
            f'assert(os.execute({lua_string(command_for(host_marker))}))')
        assert host_marker.read_text(encoding='utf-8') == 'created', 'general shell os.execute was disabled'

        # Actual packaged themes must still load/render through the isolated API.
        for file in sorted((ROOT / 'themes').glob('*.lua')):
            run('bundled-' + file.stem, file.read_text(encoding='utf-8'),
                'assert(value.kind=="prompt"); local rendered=lush.theme.render(value,{cwd="/work",home="/home/me",'
                'platform="unix",user="tester",host="host",time="12:00:00",last_status=0}); '
                'assert(type(rendered.input)=="string" and type(rendered.lines)=="table")')
        print(f'Theme sandbox checks passed: {suite.checks} subprocess cases')


if __name__ == '__main__':
    main()
