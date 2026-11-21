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
        link_target = directory / "hello world.md"
        paths = [str(link_target)]
        if os.name == "nt":
            paths.append("\\\\?\\" + str(link_target))
        for path in paths:
            linked = run(ls_call(["--hyperlink=always", path])).stdout
            assert b"\x1b]8;;" + link_target.as_uri().encode() + b"\x1b\\" in linked, linked
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

        else:
            print("Reference fls unavailable: byte-parity comparisons skipped")

        if shutil.which("git"):
            repository = directory / "repository"
            repository.mkdir()
            (repository / "tracked.txt").write_text("original", encoding="utf-8")
            for command in (["git", "init", "-q"], ["git", "add", "tracked.txt"],
                            ["git", "-c", "user.email=tests@localhost", "-c", "user.name=Lush tests",
                             "commit", "-qm", "initial"]):
                subprocess.run(command, cwd=repository, env=environment,
                               capture_output=True, check=True, timeout=20)
            if reference is not None:
                before = upstream(["-l", "--git"], cwd=repository).stdout
                actual = run("show(ls('-l','--git')); local f=assert(io.open('tracked.txt','wb')); "
                             "f:write('modified content'); f:close(); show(ls('-l','--git'))", cwd=repository)
                after = upstream(["-l", "--git"], cwd=repository).stdout
                assert actual.stdout == before + after, (actual.stdout, before, after)

            nested = repository / "nested"
            nested.mkdir()
            tracked = nested / "changed.txt"
            tracked.write_bytes(b"staged")
            subprocess.run(["git", "add", "nested/changed.txt"], cwd=repository, check=True)
            tracked.write_bytes(b"modified after staging")
            inner = nested / "inner"
            inner.mkdir()
            subprocess.run(["git", "init", "-q"], cwd=inner, check=True)
            (inner / "own.txt").write_bytes(b"inner repository")
            subprocess.run(["git", "add", "own.txt"], cwd=inner, check=True)
            result = run("to.json(ls('--git', '-R'):collect())", cwd=repository)
            statuses = {item["name"]: item["git"] for item in json.loads(result.stdout)}
            assert statuses["changed.txt"] == "NM" and statuses["own.txt"] == "N-", statuses

        browser = directory / "rename"
        browser.mkdir()

        def rename(keys: str) -> bytes:
            return run(ls_call(["--snapshot", "--keys", "r" + keys + "<Enter>"]), cwd=browser).stdout

        original = browser / "draft.txt"
        renamed = browser / "draft 2.txt"
        original.write_bytes(b"draft contents")
        assert b"renamed to draft 2.txt" in rename(" 2")
        assert not original.exists() and renamed.read_bytes() == b"draft contents"

        existing = browser / "z draft 2.txt"
        existing.write_bytes(b"keep this file")
        assert b"already exists" in rename("<Home>z ")
        assert renamed.read_bytes() == b"draft contents" and existing.read_bytes() == b"keep this file"

        if os.name == "nt":
            rename("<Home>..\\")
            assert renamed.read_bytes() == b"draft contents" and not (directory / renamed.name).exists()

        assert b"renamed to Draft 2.txt" in rename("<Home><Del>D")
        assert "Draft 2.txt" in [entry.name for entry in browser.iterdir()]

        folder = browser / "project"
        folder.mkdir()
        (folder / "nested.txt").write_bytes(b"nested contents")
        # The browser groups directories first, so the next rename selects project.
        assert b"renamed to project2" in rename("2")
        assert not folder.exists() and (browser / "project2/nested.txt").read_bytes() == b"nested contents"

        project = browser / "project2"

        def prompt(key: str, value: str) -> bytes:
            return run(ls_call(["--snapshot", "--keys", key + value + "<Enter>", str(project)]),
                       cwd=browser).stdout

        assert "created 새 폴더/".encode() in prompt("n", "새 폴더/")
        assert (project / "새 폴더").is_dir()
        assert b"created nested/dir/" in prompt("n", "nested/dir/")
        assert (project / "nested/dir").is_dir()
        assert b"created notes/sub/draft.txt" in prompt("n", "notes/sub/draft.txt")
        assert (project / "notes/sub/draft.txt").read_bytes() == b""
        assert b"already exists" in prompt("n", "nested.txt")
        assert (project / "nested.txt").read_bytes() == b"nested contents"

        assert b"draft.txt" in prompt("c", "nested/../notes/sub")
        missing = prompt("c", "missing/directory")
        assert b"cannot open" in missing and b"nested.txt" in missing, missing
        assert b"not a directory" in run(ls_call(["--snapshot", str(project / "missing")]), 2).stderr

        if os.name == "nt":
            assert b"created" in prompt("n", "native\\sub\\")
            assert (project / "native/sub").is_dir()
        else:
            assert b"created" in prompt("n", "literal\\name")
            assert (project / "literal\\name").is_file()

        print(f"Embedded fls checks passed: {checks} invocations")


if __name__ == "__main__":
    main()
