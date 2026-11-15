#!/usr/bin/env python3
"""Verify native prompt facts, Git state, caching and bounded probes in build tempdirs.

Run: python tests/prompt_context.py --exe build/lush.exe
The bounded-process cases compile a tiny test-only Git fixture with ../glosso.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import shutil
import socket
import subprocess
import tempfile
import time

from integration import ROOT, Suite, lua_string

ENVIRONMENT = {key: value for key, value in os.environ.items() if not key.upper().startswith('GIT_')}
ENVIRONMENT.update(GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL=os.devnull)


class Statements(Suite):
    def run(self, *arguments, environment=None, **options):
        return super().run(*arguments, environment=ENVIRONMENT if environment is None else environment, **options)

    def check(self, source, expected=None, **options):
        return super().check('do\n' + source + '\nend', expected, **options)


FIXTURE = r'''
#import "Process";
#import "Process/Environment";
#import "File_System/File";
#import "Strings/Utf8";
#import "Io";
#import "Time";
main :: () -> s32 {
    counter := environment_get_or("LUSH_PROMPT_TEST_COUNTER", "").unwrap_or("".clone());
    defer counter.free();
    if counter.count > 0 {
        if #pattern .Ok(file) = File.open(counter, .access = .Write,
            .disposition = .Open_Or_Create, .flags = .Append) {
            defer file.free();
            _ := file.write("call\n");
        }
    }
    mode := environment_get_or("LUSH_PROMPT_TEST_MODE", "").unwrap_or("".clone());
    defer mode.free();
    if mode == "slow" _ := sleep_ns(5000000000);
    print("# branch.oid 1234567890abcdef\n# branch.head fixture\n# branch.ab +2 -3\n# stash 4\n1 M. N... file\n? untracked\n");
    if mode == "flood" {
        block: [8192]u8;
        for i: 0..block.count block[i] = 120;
        output := File.stdout();
        for i: 0..128 _ := output.write(block[..].byte_slice_to_string());
    }
    return 0;
}
'''


def real_user():
    if os.name == 'nt':
        size = ctypes.c_uint32(1024)
        buffer = ctypes.create_unicode_buffer(size.value)
        if ctypes.windll.advapi32.GetUserNameW(buffer, ctypes.byref(size)):
            return buffer.value
        return None
    import pwd
    return pwd.getpwuid(os.geteuid()).pw_name


def git(directory, *arguments):
    result = subprocess.run(['git', '-C', str(directory), *map(str, arguments)],
                            capture_output=True, text=True, encoding='utf-8', timeout=20, env=ENVIRONMENT)
    assert result.returncode == 0, (arguments, result.stdout, result.stderr)
    return result.stdout.strip()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--exe', type=Path, default=ROOT / 'build/lush.exe')
    arguments = parser.parse_args()
    executable = arguments.exe.resolve()
    build = ROOT / 'build'
    build.mkdir(exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='prompt-context-test-', dir=build) as temporary:
        directory = Path(temporary)
        suite = Statements(executable, directory)
        expected_user = real_user()
        user_assertion = (f'assert(c.user=={lua_string(expected_user)}); ' if expected_user is not None else '')
        suite.check("local c=_lush.prompt_context(false); assert(type(c)=='table'); "
                    f"assert(c.cwd=={lua_string(str(directory))}); " + user_assertion +
                    f"assert(c.host=={lua_string(socket.gethostname())}); "
                    "assert(type(c.home)=='string' and #c.home>0); "
                    "assert(c.platform=='windows' or c.platform=='unix'); "
                    "assert(c.git==nil); assert(c.is_admin==nil or type(c.is_admin)=='boolean'); "
                    "if c.memory then assert(c.memory.total>0 and c.memory.used>=0 and c.memory.used<=c.memory.total) end; "
                    "if c.battery then assert(c.battery.percent>=0 and c.battery.percent<=100 and "
                    "type(c.battery.charging)=='boolean') end", '')
        environment = dict(ENVIRONMENT, USER='not-the-native-user', USERNAME='not-the-native-user',
                           VIRTUAL_ENV=str(directory / 'venv 한글'), CONDA_DEFAULT_ENV='ignored-conda')
        suite.check("local c=_lush.prompt_context(false); " + user_assertion +
                    "assert(c.python_env=='venv 한글')", '', environment=environment)
        environment = dict(ENVIRONMENT, VIRTUAL_ENV='', CONDA_DEFAULT_ENV='conda-environment')
        suite.check("assert(_lush.prompt_context(false).python_env=='conda-environment')", '', environment=environment)
        non_repository = directory / 'non-repository'
        non_repository.mkdir()
        (non_repository / '.git').write_text('not a Git directory\n', encoding='utf-8')
        suite.check("assert(_lush.prompt_context(true,true).git==nil)", '', cwd=non_repository)

        if shutil.which('git'):
            repository = directory / 'repository'
            repository.mkdir()
            git(repository, 'init', '--initial-branch=prompt-test')
            git(repository, 'config', 'user.name', 'Prompt Fixture')
            git(repository, 'config', 'user.email', 'prompt@example.invalid')
            tracked = repository / 'tracked.txt'
            tracked.write_text('base\n', encoding='utf-8')
            git(repository, 'add', 'tracked.txt')
            git(repository, 'commit', '-m', 'base')
            clean = "local g=assert(_lush.prompt_context(true,true).git); assert(g.branch=='prompt-test'); "
            suite.check(clean + "assert(g.dirty==0 and g.staged==0 and g.stash==0)", '', cwd=repository)
            index = repository / '.git/index'
            before = (index.stat().st_mtime_ns, hashlib.sha256(index.read_bytes()).digest())
            suite.check("local a=_lush.prompt_context(true,true); a.git.branch='mutated'; "
                        "local b=_lush.prompt_context(); assert(b.git.branch=='prompt-test'); "
                        "for i=1,40 do assert(_lush.prompt_context().git.branch=='prompt-test') end", '', cwd=repository)
            assert before == (index.stat().st_mtime_ns, hashlib.sha256(index.read_bytes()).digest()), 'prompt status changed Git index'
            tracked.write_text('changed\n', encoding='utf-8')
            (repository / 'untracked.txt').write_text('untracked\n', encoding='utf-8')
            suite.check(clean + "assert(g.dirty==2 and g.staged==0)", '', cwd=repository)
            git(repository, 'add', 'tracked.txt')
            suite.check(clean + "assert(g.dirty==1 and g.staged==1)", '', cwd=repository)
            git(repository, 'stash', 'push', '--include-untracked', '-m', 'prompt fixture stash')
            suite.check(clean + "assert(g.dirty==0 and g.staged==0 and g.stash==1)", '', cwd=repository)
            # Construct tracking refs locally; no network or upload-pack shell is needed.
            base_commit = git(repository, 'rev-parse', 'HEAD')
            git(repository, 'config', 'remote.origin.url', str(directory / 'unused-origin.git'))
            git(repository, 'config', 'remote.origin.fetch', '+refs/heads/*:refs/remotes/origin/*')
            git(repository, 'update-ref', 'refs/remotes/origin/prompt-test', base_commit)
            git(repository, 'branch', '--set-upstream-to=origin/prompt-test')
            tracked.write_text('ahead\n', encoding='utf-8')
            git(repository, 'add', 'tracked.txt')
            git(repository, 'commit', '-m', 'ahead')
            suite.check(clean + "assert(g.ahead==1 and g.behind==0)", '', cwd=repository)
            remote_commit = git(repository, 'commit-tree', base_commit + '^{tree}', '-p', base_commit, '-m', 'remote')
            git(repository, 'update-ref', 'refs/remotes/origin/prompt-test', remote_commit)
            suite.check(clean + "assert(g.ahead==1 and g.behind==1)", '', cwd=repository)
            git(repository, 'checkout', '--detach')
            expected = git(repository, 'rev-parse', '--short=7', 'HEAD')
            suite.check(f"assert(_lush.prompt_context(true,true).git.branch=={lua_string(expected)})", '', cwd=repository)

        compiler = ROOT.parent / 'glosso/build/bin' / ('glosso.exe' if os.name == 'nt' else 'glosso')
        if compiler.is_file():
            fixture_dir = directory / 'fixture-bin'
            fixture_dir.mkdir()
            fixture_source = fixture_dir / 'git.glo'
            fixture_source.write_text(FIXTURE, encoding='utf-8')
            fixture = fixture_dir / ('git.exe' if os.name == 'nt' else 'git')
            compiled = subprocess.run([str(compiler), 'compile', '--std', str(ROOT.parent / 'glosso/std'),
                            '--cache-dir', str(build / 'prompt-fixture-cache'), str(fixture_source),
                            '-o', str(fixture), '--color', 'never'], cwd=ROOT,
                           capture_output=True, text=True, encoding='utf-8', timeout=60)
            assert compiled.returncode == 0, (compiled.stdout, compiled.stderr)
            fake_repository = directory / 'bounded-probe-repository'
            (fake_repository / '.git').mkdir(parents=True)
            counter = directory / 'git-counter.txt'
            fixture_env = dict(ENVIRONMENT, PATH=str(fixture_dir) + os.pathsep + os.environ.get('PATH', ''),
                               LUSH_PROMPT_TEST_COUNTER=str(counter), LUSH_PROMPT_TEST_MODE='')
            suite.check("for i=1,20 do assert(_lush.prompt_context(false).git==nil) end", '',
                        cwd=fake_repository, environment=fixture_env)
            assert not counter.exists(), 'plain prompt unexpectedly launched Git'
            suite.check("local g=assert(_lush.prompt_context(true,true).git); "
                        "assert(g.branch=='fixture' and g.ahead==2 and g.behind==3 and g.stash==4); "
                        "assert(g.staged==1 and g.dirty==1); "
                        "for i=1,20 do assert(_lush.prompt_context().git.branch=='fixture') end; "
                        "assert(_lush.prompt_context(true,true).git.branch=='fixture')", '',
                        cwd=fake_repository, environment=fixture_env)
            assert counter.read_text().splitlines() == ['call', 'call'], 'Git cache or forced refresh did not work'
            for mode in ('slow', 'flood'):
                fixture_env['LUSH_PROMPT_TEST_MODE'] = mode
                before = time.monotonic()
                suite.check("assert(_lush.prompt_context(true,true).git==nil)", '',
                            cwd=fake_repository, environment=fixture_env, timeout=3)
                assert time.monotonic() - before < 2, mode + ' exceeded the bounded prompt budget'
        print(f'prompt context checks passed: {suite.checks} subprocess cases')


if __name__ == '__main__':
    main()
