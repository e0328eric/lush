"""Check embedded fls views, Lua record pipelines, and repeated invocations.

Run: python tests/fls.py --exe build/lush.exe [--reference ../fls/build/fls.exe]
When a reference fls exists, compare listing and animation bytes exactly.
"""

from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parents[1]


def literal(value: str) -> str:
    for width in range(20):
        equals = "=" * width
        ending = "]" + equals + "]"
        if ending not in value:
            return "[" + equals + "[" + value + ending
    raise ValueError("cannot delimit Lua string")


def ls_call(arguments: list[str]) -> str:
    return "ls(" + ",".join(literal(item) for item in arguments) + ")"


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--exe", type=Path, default=ROOT / "build/lush.exe")
    suffix = ".exe" if os.name == "nt" else ""
    parser.add_argument("--reference", type=Path,
                        default=ROOT.parent / "fls/build" / ("fls" + suffix))
    args = parser.parse_args()
    executable = args.exe.resolve(strict=True)
    reference = args.reference.resolve() if args.reference.exists() else None
    environment = os.environ.copy()
    environment.update(TZ="UTC", LC_ALL="C", COLUMNS="80", LS_COLORS="",
                       EZA_COLORS="", EXA_COLORS="", NO_COLOR="")
    checks = 0

    with tempfile.TemporaryDirectory(prefix="lush-fls-") as temporary:
        directory = Path(temporary)
        for name, value in (("file2.txt", "xx"), ("file10.txt", "abcdefghij"),
                            ("hello world.md", "a"), (".hidden", "hidden")):
            (directory / name).write_text(value, encoding="utf-8")
        (directory / "sub").mkdir()
        (directory / "sub/nested.txt").write_text("nested", encoding="utf-8")
        for file in directory.rglob("*"):
            os.utime(file, (1_700_000_000, 1_700_000_000))

        def run(source: str, status: int = 0, *, cwd: Path = directory,
                env: dict | None = None) -> subprocess.CompletedProcess:
            nonlocal checks
            result = subprocess.run([str(executable), "--no-config", "-c", source],
                                    cwd=cwd, env=env or environment,
                                    capture_output=True, timeout=30)
            assert result.returncode == status, (source, result.returncode, result.stdout, result.stderr)
            checks += 1
            return result

        def upstream(arguments: list[str], *, cwd: Path = directory,
                     env: dict | None = None) -> subprocess.CompletedProcess:
            return subprocess.run([str(reference), *arguments], cwd=cwd,
                                  env=env or environment, capture_output=True, timeout=30)

        def records(arguments: list[str]) -> list[dict]:
            return json.loads(run("to.json(" + ls_call(arguments) + ")").stdout)

        listing = run("ls()").stdout
        assert listing == b"file2.txt\nfile10.txt\n'hello world.md'\nsub\n", listing
        assert [item["name"] for item in records([])] == ["file2.txt", "file10.txt", "hello world.md", "sub"]
        assert ".hidden" in [item["name"] for item in records(["-a"])]
        assert ".hidden" in json.loads(run("to.json(ls('.', true):get('name'))").stdout)
        assert [item["name"] for item in records(["-f", "-s", "size", "-r"])] == [
            "file10.txt", "file2.txt", "hello world.md"]
        assert [item["name"] for item in records(["-D"])] == ["sub"]
        assert [item["name"] for item in records(["-I", "*.txt"])] == ["hello world.md", "sub"]
        assert [item["name"] for item in records(["-d", "sub"])] == ["sub"]
        assert [item["depth"] for item in records(["-T", "-L1"])] == [0, 1, 1, 1, 1]
        assert "nested.txt" in [item["name"] for item in records(["-R"])]
        assert "nested.txt" not in [item["name"] for item in records(["-R", "-L1"])]
        assert all(Path(item["name"]).is_absolute() for item in records(["--absolute", "-d", "sub"]))
        run("assert(not pcall(function() return ls('--lol'):collect() end))")
        run("assert(not pcall(function() return ls('--not-a-real-option'):collect() end))")
        run("assert(not pcall(function() return ls('missing-file'):collect() end))")

        if reference is not None:
            option_sets = [
                [], ["-1"], ["-l"], ["-laT", "-L2", "--icons"],
                ["-1", "-s", "size", "-r"], ["-a", "-I", "*.txt"],
                ["-G", "-w", "60"], ["-l", "--color=always", "--icons"],
                ["-l", "-b", "-g", "-h", "-H", "-i", "-S", "-n", "-o", "--time-style=full-iso"],
                ["--absolute", "-d", "sub"], ["-R", "-L2"], ["-d", "sub", "file2.txt"],
                ["--help"], ["--version"], ["--not-a-real-option"], ["missing-file"],
                ["--lol", "--snapshot", "-w", "80"], ["--lol"],
            ]
            if os.name == "nt":
                # The upstream browser joins verbatim Windows paths with '/',
                # losing entry metadata. Lush fixes that, so its snapshot has
                # real directory types and groups directories first.
                browser = run(ls_call(["--snapshot", "-w", "80"])).stdout
                assert b"sub/" in browser and browser.index(b"sub/") < browser.index(b"file2.txt"), browser
            else:
                option_sets.append(["--snapshot", "-w", "80"])
            for options in option_sets:
                expected = upstream(options)
                actual = run(ls_call(options), expected.returncode)
                assert (actual.stdout, actual.stderr) == (expected.stdout, expected.stderr), (
                    options, actual.stdout[:300], expected.stdout[:300], actual.stderr, expected.stderr)

            expected = upstream(["--lol", "--snapshot", "-w", "80"])
            actual = run("show(sl('--snapshot','-w','80'))")
            assert actual.stdout == expected.stdout and actual.stderr == expected.stderr
            once = upstream(["-l", "--color=always"]).stdout
            repeated = run("for i=1,20 do show(ls('-l','--color=always')); assert(#ls():collect()==4) end")
            assert repeated.stdout == once * 20
            first = environment | {"LS_COLORS": "*.txt=31"}
            second = environment | {"LS_COLORS": "*.txt=32"}
            expected = (upstream(["-1", "--color=always", "file2.txt"], env=first).stdout +
                        upstream(["-1", "--color=always", "file2.txt"], env=second).stdout)
            actual = run("env.LS_COLORS='*.txt=31'; show(ls('-1','--color=always','file2.txt')); "
                         "env.LS_COLORS='*.txt=32'; show(ls('-1','--color=always','file2.txt'))")
            assert actual.stdout == expected

            if shutil.which("git"):
                repository = directory / "repository"
                repository.mkdir()
                (repository / "tracked.txt").write_text("original", encoding="utf-8")
                for command in (["git", "init", "-q"], ["git", "add", "tracked.txt"],
                                ["git", "-c", "user.email=tests@localhost", "-c", "user.name=Lush tests",
                                 "commit", "-qm", "initial"]):
                    subprocess.run(command, cwd=repository, env=environment,
                                   capture_output=True, check=True, timeout=20)
                before = upstream(["-l", "--git"], cwd=repository).stdout
                actual = run("show(ls('-l','--git')); local f=assert(io.open('tracked.txt','wb')); "
                             "f:write('modified content'); f:close(); show(ls('-l','--git'))", cwd=repository)
                after = upstream(["-l", "--git"], cwd=repository).stdout
                assert actual.stdout == before + after, (actual.stdout, before, after)
        else:
            print("Reference fls unavailable: byte-parity comparisons skipped")
        print(f"Embedded fls checks passed: {checks} invocations")


if __name__ == "__main__":
    main()
