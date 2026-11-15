#!/usr/bin/env python3
"""Exercise shell conveniences and executable lookup with isolated fixtures."""
import argparse
import os
from pathlib import Path
import subprocess
import tempfile
import time


def quote(value):
    return '[=[' + str(value) + ']=]'


def check(executable):
    usage = subprocess.run([str(executable), '--help'], capture_output=True, text=True,
                           encoding='utf-8', timeout=15)
    assert usage.returncode == 0
    for heading in ('Usage:', 'Flags:', 'Parameters:', 'Input/output types:', 'Examples:'):
        assert heading in usage.stdout, heading
    with tempfile.TemporaryDirectory(prefix='lush-shell-') as temporary:
        root = Path(temporary)
        checks = 0

        def run(code, environment=None, status=0):
            nonlocal checks
            result = subprocess.run([str(executable), '--no-config', '-c', 'do\n' + code + '\nend'],
                                    cwd=root, env=environment, capture_output=True,
                                    text=True, encoding='utf-8', timeout=15)
            assert result.returncode == status, (result.returncode, result.stdout, result.stderr)
            checks += 1
            return result.stdout

        script = root / 'source 한글.lua'
        script.write_bytes(b'\xef\xbb\xbf#!/usr/bin/env lush\n' +
                           'sourced_value = (sourced_value or 0) + 1\n'
                           'return ..., sourced_value\n'.encode('utf-8'))
        assert run(f'local a,b=source({quote(script)},42); assert(a==42 and b==1); '
                   f'assert(sourced_value==1); source({quote(script)}); assert(sourced_value==2)') == ''
        script.write_text('error("source failure marker")\n', encoding='utf-8')
        run(f'local ok,msg=pcall(source,{quote(script)}); assert(not ok and msg:find("source failure marker",1,true))')
        run('local ok=pcall(source,"missing.lua"); assert(not ok)')
        assert run('printf("%s:%d", "value", 42)') == 'value:42'
        run('assert(describe(json.null)=="null"); assert(describe(json.object())=="record"); '
            'assert(describe({1,2})=="list"); assert(describe({name="x"})=="record"); '
            'assert(describe(stream({}))=="stream"); assert(describe(cmd.git())=="command"); '
            'assert(describe(42)=="integer"); assert(describe("x")=="string")')
        run('local v=version(); assert(v.name=="lush" and v.version=="0.1.0" and v.lua==_VERSION); '
            'assert(v.platform=="windows" or v.platform=="unix")')
        run('assert(contains({false,2,"x"},false)); assert(contains(stream({1,2}),2)); '
            'assert(not contains({1,2},3)); assert(not pcall(contains,{name="x"},"x"))')
        run('local ok,msg=pcall(clear); assert(not ok and msg:find("interactive",1,true))')

        left, right = root / 'first path 한글', root / 'second path'
        left.mkdir()
        right.mkdir()
        suffix = '.exe' if os.name == 'nt' else ''
        for directory in (left, right):
            candidate = directory / ('lush-lookup-test' + suffix)
            candidate.write_bytes(b'lookup fixture')
            if os.name != 'nt': candidate.chmod(0o700)
        environment = dict(os.environ, PATH=os.pathsep.join((str(left), str(right))))
        if os.name == 'nt': environment['PATHEXT'] = '.EXE;.COM;.BAT;.CMD'
        expected = left / ('lush-lookup-test' + suffix)
        found = run('io.write(assert(which("lush-lookup-test")))', environment)
        assert Path(found) == expected, (repr(found), str(expected))
        assert Path(run(f'io.write(assert(which({quote(expected)})))', environment)) == expected
        run('assert(which("missing-lookup-test-xyz")==nil); assert(not pcall(which,"")); '
            'assert(not pcall(which,"bad\\0name"))', environment)
        if os.name == 'nt':
            batch = left / 'lush-batch-test.cmd'
            batch.write_text('@exit /b 0\n', encoding='ascii')
            environment['PATH'] = '"' + str(left) + '";' + str(right)
            assert Path(run('io.write(assert(which("lush-batch-test")))', environment)) == batch

        run('for _,name in ipairs({"source","which","describe","version","clear","printf","contains"}) '
            'do assert(lush[name]==_G[name]) end; assert(filter==where and lush.filter==filter)')
        if os.name == 'nt':
            from tui_cursor import Pseudoconsole
            terminal = Pseudoconsole(executable, "print('before-clear'); clear(); print('after-clear')", 80, 25)
            try:
                output, deadline = bytearray(), time.monotonic() + 8
                while time.monotonic() < deadline:
                    output.extend(terminal.receive(.05))
                    if terminal.poll() is not None:
                        output.extend(terminal.receive(.1))
                        break
                assert terminal.poll() == 0 and b'after-clear' in output, output
                checks += 1
            finally:
                terminal.close()
        print(f'Shell convenience checks passed: {checks}')


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=Path(__file__).resolve().parents[1] / 'build/lush.exe')
    args = parser.parse_args()
    check(args.exe.resolve(strict=True))


if __name__ == '__main__':
    main()
