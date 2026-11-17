#!/usr/bin/env python3
"""Exercise Lush's embedded Lua, structured values and native process pipelines."""

import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def lua_string(value):
    """Quote UTF-8 text as a Lua literal without shell quoting or interpolation."""
    value = str(value)
    for width in range(20):
        equals = '=' * width
        closing = ']' + equals + ']'
        if closing not in value and not value.startswith(('\n', '\r')):
            return '[' + equals + '[' + value + closing
    raise ValueError('could not delimit Lua string')


class Suite:
    def __init__(self, executable, directory):
        self.executable = executable
        self.directory = directory
        self.checks = 0

    def run(self, *arguments, source=None, status=0, cwd=None, input_text=None, timeout=20,
            no_config=True, environment=None, binary=False):
        command = [str(self.executable)]
        if no_config:
            command.append('--no-config')
        command += map(str, arguments)
        if source is not None:
            command += ['-c', source]
        result = subprocess.run(
            command, cwd=cwd or self.directory, input=input_text,
            capture_output=True, text=not binary, encoding=None if binary else 'utf-8', timeout=timeout,
            env=environment,
        )
        if status is not None:
            assert result.returncode == status, (
                command, result.returncode, result.stdout, result.stderr,
            )
        self.checks += 1
        return result

    def check(self, source, expected=None, **options):
        result = self.run(source=source, **options)
        if expected is not None:
            assert result.stdout == expected, (source, result.stdout, result.stderr)
        return result


def check_cli(suite):
    help_text = suite.run('--help').stdout
    assert 'lush' in help_text.lower() and '-c' in help_text
    assert suite.run('--version').stdout.lower().startswith('lush ')
    assert suite.run('--definitely-not-an-option', status=None).returncode != 0
    assert suite.run('-c', status=None).returncode != 0
    suite.check('6 * 7', '42\n')
    suite.check('1 | 2', '3\n')
    suite.check('print(_VERSION)', 'Lua 5.5\n')
    suite.check('local total = 0; for i = 1, 10 do total = total + i end; print(total)', '55\n')
    suite.check('local a = {x = 4}; local function f(n) return n * a.x end; print(f(3))', '12\n')
    failure = suite.run(source='local =', status=None)
    assert failure.returncode != 0 and failure.stderr.strip()
    failure = suite.run(source='error("deliberate failure")', status=None)
    assert failure.returncode != 0 and 'deliberate failure' in failure.stderr
    failure = suite.run(source='git status', status=None)
    assert failure.returncode != 0, 'ordinary command grammar must not replace Lua grammar'


def check_scripts(suite):
    script = suite.directory / 'arguments and loops.lua'
    script.write_text(
        'assert(type(arg) == "table")\n'
        f'assert(arg[0] == {lua_string(script)})\n'
        'assert(arg[1] == "space in argument")\n'
        'assert(arg[2] == "quote\\\"and$literal")\n'
        'local values = {}\n'
        'for i = 1, 3 do values[#values + 1] = i * i end\n'
        'print(table.concat(values, ","))\n',
        encoding='utf-8',
    )
    result = suite.run(script, 'space in argument', 'quote"and$literal')
    assert result.stdout == '1,4,9\n', result
    result = suite.run('missing-script.lua', status=None)
    assert result.returncode != 0 and result.stderr.strip()
    suite.run('-c', 'assert(arg[0] == "-c" and arg[1] == "code argument")', '--', 'code argument')
    script.write_text('return 42\n', encoding='utf-8')
    assert suite.run(script).stdout == '', 'script return values must not auto-display'
    script.write_bytes(b'\xef\xbb\xbf#!/usr/bin/env lush\nprint("BOM and shebang ok")\n')
    assert suite.run(script).stdout == 'BOM and shebang ok\n'
    script.write_bytes(b'\xef\xbb\xbf#!/usr/bin/env lush\nlocal value = 1\nerror("original line")\n')
    failure = suite.run(script, status=None)
    assert failure.returncode != 0 and ':3:' in failure.stderr, failure

    suite.check('exit(7); print("unreachable")', '', status=7)
    suite.check('local function quit() exit() end; quit(); print("unreachable")', '')
    assert 'unreachable' not in suite.run(input_text='exit()\nprint("unreachable")\n').stdout

    # Separate REPL submissions share globals, while lexical locals stay local.
    result = suite.run(input_text='persisted = 41\nprint(persisted + 1)\nlocal private = 9\nprint(private == nil)\n')
    assert '42\n' in result.stdout and 'true\n' in result.stdout, result
    result = suite.run(input_text='for i = 1, 3 do\nprint(i)\nend\n')
    assert '1\n2\n3\n' in result.stdout, result


def check_configuration(suite):
    configuration = suite.directory / 'custom init.lua'
    configuration.write_text('configured_value = 41\nreturn "do not display config returns"\n', encoding='utf-8')
    configured = suite.run('--config', configuration, source='print(configured_value + 1)', no_config=False)
    assert configured.stdout == '42\n', configured
    disabled = suite.run('--config', configuration, source='print(configured_value == nil)', status=2)
    assert disabled.stderr.strip(), disabled
    environment = dict(os.environ, LUSH_CONFIG=str(configuration))
    configured = suite.run(source='print(configured_value)', no_config=False, environment=environment)
    assert configured.stdout == '41\n', configured
    suite.check('local _ = assert(configured_value == nil)', '', environment=environment)
    missing = suite.run('--config', suite.directory / 'missing init.lua', no_config=False, status=None)
    assert missing.returncode != 0 and missing.stderr.strip()
    configuration.write_text('error("broken configuration")\n', encoding='utf-8')
    failed = suite.run('--config', configuration, source='print("unreachable")', no_config=False, status=None)
    assert failed.returncode != 0 and 'broken configuration' in failed.stderr
    assert 'unreachable' not in failed.stdout


def check_filesystem(suite):
    root = suite.directory / 'records with spaces'
    root.mkdir()
    binary = root / 'raw bytes 한글.bin'
    payload = bytes(range(256)) + b'\r\nline\n\x00end'
    binary.write_bytes(payload)
    result = suite.run(source='assert(cat==lush.cat and lush.read==cat and lush.open==open); '
                       f'io.write(cat({lua_string(binary)}))', binary=True)
    assert result.stdout == payload, 'cat changed file bytes'
    assert suite.run(source=f'local _=io.write(lush.read({lua_string(binary)}))', binary=True).stdout == payload
    for name, contents in [('a.txt', 'one'), ('b.txt', 'second'), ('한글.txt', 'UTF-8')]:
        (root / name).write_text(contents, encoding='utf-8')
    (root / '.hidden').write_text('hidden', encoding='utf-8')
    (root / 'folder').mkdir()
    suite.check(
        f'local original = pwd(); cd({lua_string(root)}); '
        f'assert(pwd() == {lua_string(root.as_posix())}); '
        'assert(pwd() == lush.pwd() and select("#", pwd()) == 1); '
        'assert(pwd() ~= original); cd(original); assert(pwd() == original); print("cwd ok")',
        'cwd ok\n',
    )
    suite.check(
        'env.LUSH_INTEGRATION_VALUE = "space and 한글"; '
        'assert(env.LUSH_INTEGRATION_VALUE == "space and 한글"); '
        'env.LUSH_INTEGRATION_VALUE = nil; assert(env.LUSH_INTEGRATION_VALUE == nil)',
        '',
    )
    suite.check(
        f'local rows = ls({lua_string(root)}):collect(); '
        'local names = {}; for _, row in ipairs(rows) do names[row.name] = row end; '
        'assert(names["a.txt"] and names["b.txt"] and names["한글.txt"]); '
        'assert(names["a.txt"].size == 3); assert(not names[".hidden"]); '
        'print("records ok")',
        'records ok\n',
    )
    suite.check(
        f'local rows = ls({lua_string(root)}):where(function(f) return f.name:match("%.txt$") end)'
        ':sort_by("name"):select("name", "size"):take(2):collect(); '
        'assert(#rows == 2 and rows[1].name == "a.txt" and rows[2].name == "b.txt"); '
        'assert(rows[1].size == 3)',
        '',
    )
    failed = suite.run(source=f'cd({lua_string(root / "missing")})', status=None)
    assert failed.returncode != 0 and failed.stderr.strip()
    failed = suite.run(source=f'ls({lua_string(root / "missing")}):collect()', status=None)
    assert failed.returncode != 0 and failed.stderr.strip()


def check_structured_data(suite):
    suite.check(
        'local rows = (stream{{name="c", size=3}, {name="a", size=1}, {name="b", size=2}} '
        '| where(function(row) return row.size > 1 end) | sort_by("name") '
        '| select("name", "size")):collect(); '
        'assert(#rows == 2 and rows[1].name == "b" and rows[2].size == 3); '
        'assert(stream{1,2,3}:each(function(n) return n * 2 end):skip(1):count() == 2); '
        'assert(select("#", 1, nil, 3) == 3); assert(select(2, "a", "b") == "b")',
        '',
    )
    suite.check(
        'local data = json.object{empty=json.array{}, object=json.object{}, null=json.null, '
        'flag=false, text="한글\\n\\t\\\"\\\\", nested={1,2,3}}; '
        'local encoded = json.encode(data); local decoded = json.decode(encoded); '
        'assert(decoded.flag == false and decoded.null == json.null); '
        'assert(decoded.text == data.text and decoded.nested[3] == 3); '
        'assert(json.encode(decoded.empty) == "[]"); '
        'assert(json.encode(decoded.object) == "{}"); '
        'assert(not pcall(json.decode, "{broken}")); '
        'assert(not pcall(json.decode, "true trailing")); '
        'local cycle={}; cycle.self=cycle; assert(not pcall(json.encode, cycle)); '
        'print("json ok")',
        'json ok\n',
    )
    suite.check(
        'local values = from.json("[1,2,3]"):collect(); assert(values[3] == 3); '
        'local rows = lines("one\\r\\ntwo\\n"):collect(); '
        'assert(#rows == 2 and rows[1] == "one" and rows[2] == "two")',
        '',
    )
    destination = suite.directory / 'structured data.json'
    suite.check(
        f'local _ = stream{{{{name="한글", active=false}}}} | to.json() | save({lua_string(destination)}); '
        f'local decoded = json.decode(cat({lua_string(destination)})); '
        'assert(decoded[1].name == "한글" and decoded[1].active == false)',
        '',
    )
    assert json.loads(destination.read_text(encoding='utf-8')) == [{'name': '한글', 'active': False}]


def check_processes(suite):
    python = lua_string(sys.executable)
    # Whitespace prevents '[' + a long string from becoming Lua's string-call sugar.
    invoke = f'cmd[ {python} ]'
    raw = suite.run(source='local _ = io.write("a\\r\\nb\\0c"); '
                          'local _ = io.stderr:write("x\\r\\ny\\0z")', binary=True)
    assert raw.stdout == b'a\r\nb\0c' and raw.stderr == b'x\r\ny\0z', raw
    suite.check(
        f'print("parent before"); run({invoke}("-c", "print(\'child\')")); print("parent after")',
        'parent before\nchild\nparent after\n',
    )
    arguments = ['space in arg', '"quote"', 'dollar$HOME', 'semi;colon', 'bar|literal', '한글', '']
    payload = 'import json,sys; print(json.dumps(sys.argv[1:]))'
    argv = ', '.join(lua_string(item) for item in arguments)
    result = suite.run(source=f'local r = capture({invoke}("-c", {lua_string(payload)}, {argv})); '
                       'assert(r.ok and r.code == 0); io.write(r.stdout)')
    assert json.loads(result.stdout) == arguments, result

    payload = 'import sys; sys.stdout.write("out\\x00bytes"); sys.stderr.write("err bytes")'
    suite.check(
        f'local r = capture({invoke}("-c", {lua_string(payload)})); '
        'assert(r.stdout == "out\\0bytes" and r.stderr == "err bytes" and r.ok)',
        '',
    )
    payload = 'import sys; sys.stdout.write("x" * 262144); sys.stderr.write("y" * 262144)'
    suite.check(
        f'local r = capture({invoke}("-c", {lua_string(payload)})); '
        'assert(r.ok and #r.stdout == 262144 and #r.stderr == 262144)',
        '',
    )
    suite.check(
        f'local r = capture({invoke}("-c", "import sys; sys.exit(7)")); '
        'assert(not r.ok and r.code == 7); print("exit status ok")',
        'exit status ok\n',
        status=None,
    )

    # A producer larger than OS pipe buffers detects sequential-spawn deadlocks.
    producer = 'import sys; sys.stdout.buffer.write(b"x" * 1048576); sys.stderr.write("producer error")'
    consumer = ('import sys; data=sys.stdin.buffer.read(); '
                'sys.stdout.buffer.write(str(len(data)).encode()+b"\\n"); '
                'sys.stderr.write("consumer error")')
    suite.check(
        f'local r = capture({invoke}("-c", {lua_string(producer)}) | '
        f'{invoke}("-c", {lua_string(consumer)})); '
        'assert(r.ok and r.stdout == "1048576\\n"); '
        'assert(r.stderr:find("producer error", 1, true)); '
        'assert(r.stderr:find("consumer error", 1, true)); print("pipeline ok")',
        'pipeline ok\n', timeout=30,
    )
    missing = suite.run(source='run(cmd.lush_executable_that_does_not_exist())', status=None)
    assert missing.returncode != 0 and missing.stderr.strip()
    nul = suite.run(source=f'run({invoke}("-c", "pass", "bad\\0arg"))', status=None)
    assert nul.returncode != 0 and nul.stderr.strip()
    suite.check(
        f'assert(not pcall(function() return {invoke}("-c", "pass", nil) end)); '
        f'assert(not pcall(function() return capture({{[1]={python}, [3]="-c"}}) end)); '
        f'assert(not pcall(function() return stream{{{{name="record"}}}} | {invoke}("-c", "pass") end))',
        '',
    )
    suite.check(
        f'local r = capture({invoke}("-c", "import sys; sys.exit(3)") | '
        f'{invoke}("-c", "import sys; sys.stdin.buffer.read()")); '
        'assert(not r.ok and r.code == 3 and r.statuses[1] == 3 and r.statuses[2] == 0); '
        'assert(not pcall(function() r:check() end)); print("pipefail ok")',
        'pipefail ok\n', status=None,
    )
    suite.check(
        f'local ok = pcall(function() return capture({invoke}("-c", "import time; time.sleep(30)") '
        '| cmd.lush_missing_pipeline_stage()) end); assert(not ok); print("cleanup ok")',
        'cleanup ok\n', timeout=8, status=None,
    )

    # Environment and cwd changes must reach native children.
    child = 'import os; print(os.environ["LUSH_CHILD_VALUE"]); print(os.path.basename(os.getcwd()))'
    folder = suite.directory / 'child cwd'
    folder.mkdir()
    suite.check(
        'env.LUSH_CHILD_VALUE = "inherited"; '
        f'cd({lua_string(folder)}); local r = capture({invoke}("-c", {lua_string(child)})); '
        'assert(r.ok); io.write(r.stdout)',
        'inherited\nchild cwd\n',
    )


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build' / ('lush.exe' if os.name == 'nt' else 'lush'))
    arguments = parser.parse_args()
    executable = arguments.exe.resolve()
    assert executable.is_file(), f'Build Lush first; executable not found: {executable}'
    with tempfile.TemporaryDirectory(prefix='lush-integration-') as temporary:
        suite = Suite(executable, Path(temporary))
        check_cli(suite)
        check_scripts(suite)
        check_configuration(suite)
        check_filesystem(suite)
        check_structured_data(suite)
        check_processes(suite)
        print(f'{suite.checks} Lush integration checks passed')


if __name__ == '__main__':
    main()
