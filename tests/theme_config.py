#!/usr/bin/env python3
"""Selected-only caching of sandboxed theme files. All fixtures stay in build/."""
import argparse
from pathlib import Path
import shutil
import tempfile
from integration import ROOT, Suite, lua_string


def descriptor(prefix):
    return f'local t=lush.theme\nreturn t.prompt{{input={{t.text({lua_string(prefix)})}}}}\n'


def builder(prefix):
    return ('local t=lush.theme\nlocal calls=0\nreturn function(context,options)\n'
            'calls=calls+1\nreturn t.prompt{input={t.text(' + lua_string(prefix) + '..calls.."> ")}}\nend\n')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    args = parser.parse_args()
    with tempfile.TemporaryDirectory(prefix='theme-config-', dir=ROOT / 'build') as temporary:
        directory = Path(temporary)
        themes = directory / 'themes'
        themes.mkdir()
        bundled = sorted((ROOT / 'themes').glob('*.lua'))
        assert bundled, 'external theme examples are missing'
        for file in bundled:
            packaged = args.exe.resolve().parent / 'themes' / file.name
            assert packaged.read_bytes() == file.read_bytes(), file.name
            shutil.copyfile(packaged, themes / file.name)
        marker = directory / 'unselected-executed.txt'
        unselected = {
            'unselected-error': 'error("unselected root ran")\n',
            'unselected-syntax': 'this is not valid Lua !!!\n',
            'unselected-dependency': 'return require("unselected_theme_dependency")\n',
            'unselected-side-effect': f'local f=assert(io.open({lua_string(marker)},"wb")); f:write("executed"); f:close()\n',
        }
        for name, contents in unselected.items():
            (themes / (name + '.lua')).write_text(contents, encoding='utf-8')
        (themes / 'plain.lua').write_text('error("reserved plain file ran")\n', encoding='utf-8')
        custom = themes / 'not-a-built-in.lua'
        custom.write_text(builder('custom'), encoding='utf-8')
        (themes / 'second.lua').write_text(builder('second'), encoding='utf-8')
        (themes / 'override.lua').write_text(builder('fallback'), encoding='utf-8')
        unicode_name = 'selected 한글'
        (themes / (unicode_name + '.lua')).write_text(descriptor('unicode> '), encoding='utf-8')
        selected_error = themes / 'selected-error.lua'
        selected_error.write_text('error("old selected failure")\n', encoding='utf-8')
        init = directory / 'init.lua'
        default_init = (ROOT / 'src/default_init.lua').read_text(encoding='utf-8')
        suite = Suite(args.exe.resolve(strict=True), directory)

        def evaluate(code, selected='not-a-built-in', extra=''):
            setting = 'nil' if selected is None else 'false' if selected is False else lua_string(selected)
            # init.lua and CLI code are trusted; only external theme files are sandboxed.
            init.write_text(default_init + f'\nlush.config.theme={setting}\n'
                            'lush.config.theme_options={icons=false,git=false,time=false}\n' + extra + '\n', encoding='utf-8')
            return suite.run('--config', init, source='do\n' + code + '\nend', no_config=False, timeout=8)

        evaluate('assert(lush.themes==nil and lush.theme.sources==nil); '
                 f'assert(lush.config_dir=={lua_string(directory)}); assert(lush.config_file=={lua_string(init)}); '
                 'assert(next(lush.config.themes or {})==nil); '
                 'local a=assert(lush.theme.load("not-a-built-in")); '
                 'assert(rawequal(a,assert(lush.theme.load("not-a-built-in")))); '
                 'for i=1,10 do assert(lush.prompt()=="custom"..i.."> ") end')
        evaluate('assert(lush.prompt()=="custom1> "); '
                 'lush.config.theme="second"; assert(lush.prompt()=="second1> "); '
                 'assert(lush.prompt()=="second2> "); '
                 'lush.config.theme="not-a-built-in"; assert(lush.prompt()=="custom2> ")')
        evaluate('assert(lush.prompt()=="unicode> ")', selected=unicode_name)
        assert not marker.exists(), 'an unselected file executed'
        evaluate('assert(lush.prompt()=="registered> "); assert(lush.prompt()=="registered> ")', selected='override',
                 extra='lush.config.themes={override=lush.theme.prompt{input={lush.theme.text("registered> ")}}}')
        evaluate('assert(lush.prompt()=="function> "); assert(lush.prompt()=="function> "); assert(registry_calls==2)',
                 selected='override', extra='local calls=0; lush.config.themes={override=function(context,options) '
                 'calls=calls+1; registry_calls=calls; return lush.theme.prompt{input={lush.theme.text("function> ")}} end}')
        evaluate('assert(lush.prompt()=="fallback1> "); '
                 'lush.config.themes={override=lush.theme.prompt{input={lush.theme.text("override> ")}}}; '
                 'assert(lush.prompt()=="override> "); lush.config.themes.override=nil; '
                 'assert(lush.prompt()=="fallback2> ")', selected='override')
        for invalid in ('false', '123'):
            evaluate('local ok,msg=pcall(lush.prompt); assert(not ok and type(msg)=="string")', selected='override',
                     extra='lush.config.themes={override=' + invalid + '}')
        for selected in (None, False, 'plain'):
            evaluate('assert(type(lush.prompt())=="string")', selected=selected)
        evaluate('assert(lush.prompt()=="legacy> ")', extra='lush.config.prompt="legacy> "')
        other = directory / 'other-config'
        (other / 'themes').mkdir(parents=True)
        (other / 'themes/not-a-built-in.lua').write_text(builder('other'), encoding='utf-8')
        evaluate('assert(lush.prompt()=="custom1> "); '
                 f'lush.config_dir={lua_string(other)}; assert(lush.prompt()=="other1> "); '
                 f'lush.config_dir={lua_string(directory)}; assert(lush.prompt()=="custom2> ")')

        # Fresh contents after init prove unselected attempts were not cached failures.
        code = []
        for name in unselected:
            file = themes / (name + '.lua')
            code += [f'lush.write({lua_string(file)}, {lua_string(descriptor("fresh> "))})',
                     f'local value=assert(lush.theme.load({lua_string(name)}))',
                     'assert(lush.theme.render(value,{cwd="/test"}).input=="fresh> ")']
        evaluate('; '.join(code), selected=None)
        assert not marker.exists(), 'an unselected file escaped the sandbox'
        outside = directory / 'escape.lua'
        outside.write_text(descriptor('outside> '), encoding='utf-8')
        (themes / 'nested').mkdir()
        (themes / 'nested/child.lua').write_text(descriptor('nested> '), encoding='utf-8')
        for name in ('.lua', '..lua', '...lua'):
            (themes / name).write_text(descriptor('invalid> '), encoding='utf-8')
        bad_names = ['', '.', '..', '../escape', '..\\escape', 'nested/child', 'nested\\child',
                     str(outside.with_suffix('')), '/absolute', '\\absolute', 'C:/absolute', 'C:\\absolute', 'C:relative']
        bad_lua = '{' + ','.join(lua_string(name) for name in bad_names) + '}'
        evaluate(f'local bad={bad_lua}; '
                 'for _,code in ipairs{0,9,10,27,127} do bad[#bad+1]="bad"..string.char(code) end; '
                 'for _,name in ipairs(bad) do local ok,value,msg=pcall(lush.theme.load,name); '
                 'assert(ok and value==nil and type(msg)=="string"); assert(msg:find("theme.load: name",1,true)==1); '
                 'lush.config.theme=name; assert(not pcall(lush.prompt)) end', selected=None)
        evaluate('local value,msg=lush.theme.load("selected-error"); assert(value==nil and type(msg)=="string"); '
                 f'lush.write({lua_string(selected_error)}, {lua_string(descriptor("recovered> "))}); '
                 'local again,msg2=lush.theme.load("selected-error"); assert(again==nil and type(msg2)=="string")', selected=None)
        evaluate('assert(lush.prompt()=="recovered> ")', selected='selected-error')
        late = themes / 'late.lua'
        evaluate('local value,msg=lush.theme.load("late"); assert(value==nil and type(msg)=="string"); '
                 f'lush.write({lua_string(late)}, {lua_string(descriptor("late> "))}); '
                 'local again,msg2=lush.theme.load("late"); assert(again==nil and type(msg2)=="string")', selected=None)
        evaluate('assert(lush.prompt()=="late> ")', selected='late')
        evaluate('assert(lush.prompt()=="custom1> "); '
                 f'lush.write({lua_string(custom)}, {lua_string(descriptor("edited> "))}); '
                 'assert(lush.prompt()=="custom2> ")')
        evaluate('assert(lush.prompt()=="edited> ")')
        custom.unlink()
        evaluate('local ok,msg=pcall(lush.prompt); assert(not ok and type(msg)=="string" and msg:find("not-a-built-in",1,true))')
        for file in bundled:
            evaluate('local value=assert(lush.theme.load(' + lua_string(file.stem) + ')); '
                     'assert(value.kind=="prompt"); local rendered=lush.prompt(); '
                     'assert(type(rendered)=="string" or type(rendered)=="table")', selected=file.stem)
        editable = themes / bundled[0].name
        editable.write_text(descriptor('bundled-edited> '), encoding='utf-8')
        evaluate('assert(lush.prompt()=="bundled-edited> ")', selected=bundled[0].stem)
        editable.unlink()
        evaluate('local ok,msg=pcall(lush.prompt); assert(not ok and type(msg)=="string")', selected=bundled[0].stem)
        suite.run(source='do assert(lush.themes==nil and lush.config.themes==nil); '
                  f'lush.config_dir={lua_string(directory)}; assert(type(lush.prompt())=="string") end', timeout=8)
        assert not marker.exists(), 'untrusted code created a side-effect marker'
        print(f'Selected-only sandboxed theme config checks passed: {suite.checks}')


if __name__ == '__main__':
    main()
