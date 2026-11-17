# Lush

A structured shell implemented in [Glosso](../glosso), with **standard Lua 5.5 as its
only language**. Lua provides variables, functions, loops, tables, modules, and
configuration. Lush adds libraries for filesystem records, data pipelines, and
external programs, inspired by Nushell.

## Build and run

Use a recent Glosso installation with its bundled Lua sources:

```sh
glosso compile first.glo --cache-dir build/cache
```

This writes `build/lush.exe` on Windows and `build/lush` on Linux. The Lua runtime
and shell library are embedded in the executable; no Lua installation or runtime
source files are needed alongside it. Like the neighboring Glosso projects,
`first.glo` is a compile-time build entry point.

To use the sibling compiler checkout explicitly, from this directory:

```powershell
..\glosso\build\bin\glosso.exe compile --std ..\glosso\std --cache-dir build/cache first.glo
.\build\lush.exe
```

Glosso's bundled Lua currently supports Windows MSVC and Linux targets. Windows
is the platform exercised by this project's integration suite so far.

## Pure Lua at the prompt

```lua
2 + 3
ls()
ls():where(function(f) return f.type == "file" end):select("name", "size")
ls():sort_by("size", true):take(5)
cmd.git("status", "--short")
```

The prompt accepts Lua expressions and Lua statements. Expression results are
displayed automatically. A displayed command object executes with the terminal
attached; a displayed structured pipeline renders its records as a table.

Multiline Lua works normally:

```lua
for _, branch in ipairs({"main", "dev"}) do
    run(cmd.git("log", "--oneline", branch)):check()
end
```

Globals persist between submissions. `local` retains normal Lua scope and lasts
only for its submitted chunk. No shell grammar, implicit executable globals, or
rewriting of Lua source is involved.

The interactive editor supports Unicode text, cursor movement, Home/End,
Backspace/Delete, Lua syntax highlighting, persistent Up/Down history, history autosuggestions, executable
and path completion with Tab, and bracketed paste. Ctrl+L clears the screen and
redraws the prompt with the current input.
At the start of a `... ` continuation line, Backspace removes the newline and
puts the cursor at the join, keeping any text to its right.
Ctrl+C clears the current submission; Ctrl+D on an empty line exits.
The terminal's normal modes are restored before running Lua or an external
program. Redirected stdin uses a prompt-free, line-oriented REPL.
Full-screen views paint with the text cursor hidden. The file browser shows a
caret only in an active input field, after positioning it; the takeoff animation
keeps it hidden until it exits.

Tab completes executable names after `cmd.` and in `cmd("...")` or `cmd["..."]`.
Names that need quoting are inserted as bracket lookups, such as `cmd["my-tool"]`.
Executable names come from the current `PATH`; changing `env.PATH` takes effect on
the next completion. On Windows, completion recognizes supported executable
formats from `PATHEXT`; on Unix, it checks execute access.

Inside a quoted argument, Tab completes file paths, including spaces and Unicode.
Directories receive a trailing slash; `cd("...")` completes directories only.
Completion preserves the text after the cursor and the string's quoting. It
inserts the common prefix for ambiguous matches and shows choices on another Tab.
The completion hook remains configurable as `lush.complete(source)`.

Inside a callback on a known `ls()` stream, Tab after the record parameter
(`f.` in `ls():where(function(f) return f.`) lists file fields with their types
and descriptions. The hints also use preceding continuation lines, without
executing the listing or callback. `help(ls)` documents all possible output
fields, while `ls():columns()` shows the fields present in the current results.

## Prompt themes

Theme definitions are Lua files built with `lush.theme` components.
The component library supplies rendering utilities. Select a file by name or
register a descriptor or builder in `lush.config.themes`.

The distribution includes three external examples:

| File | Layout |
| --- | --- |
| [themes/powerlevel10k_classic.lua](themes/powerlevel10k_classic.lua) | Slate powerline directory/Git segments, session and clock at the right, a status input marker |
| [themes/easy-term.lua](themes/easy-term.lua) | Folder-oriented colored segments, Git state colors, clock, and available memory/Python/duration information |
| [themes/iterm2.lua](themes/iterm2.lua) | Colored user/directory/Git/status segments, with clock and available battery/Python information at the right |

Builds copy these files to `build/themes/` beside the executable. Default
configuration setup copies missing files from that external `themes/` directory
to `get_config_dir()/lush/themes/`, preserving files you have edited. The default
`init.lua` does not scan or execute that directory.

Select a filename stem in `get_config_dir()/lush/init.lua`:

```lua
lush.config.theme = "powerlevel10k_classic" -- or "easy-term", "iterm2"
lush.config.theme_options = {icons = true, git = true, time = true}
```

Lush first looks up the selected name in `lush.config.themes`. If no entry
exists, it loads only `lush.config_dir/themes/<name>.lua`, caching that file's
returned descriptor or builder for the session. Lush does not automatically
execute the other theme files. A returned builder runs for each new prompt;
its file runs once. Setting `theme` to nil or `"plain"` uses the default path
prompt and loads no theme file. A missing or invalid selected file reports an
`unknown prompt theme` error with the load details.

You can load a file explicitly or register it under another name:

```lua
lush.config.themes = lush.config.themes or {}
lush.config.themes.work = assert(lush.theme.load("easy-term"))
lush.config.theme = "work"

```

`lush.theme.load(name)` accepts a filename stem within the configuration's
`themes` directory, without the `.lua` extension or a directory path. It returns
the descriptor or builder, or `nil, message` on failure. Both successes and
failures are cached by configuration directory and name for the session;
restart Lush after editing or adding a cached file.

Named files and `lush.theme.load()` run in a separate, restricted Lua state.
The file can use basic Lua functions, private `string`, `math`, `table`, and
`utf8` libraries, and the pure `lush.theme` component/rendering API. Its `_G`
refers only to that theme's globals. String pattern functions and `string.dump`
are unavailable; `string.find` performs literal searches. Shell commands,
filesystem/process APIs, `os`, `io`, `package`, `debug`, code loaders,
`pcall`/`xpcall`, and `lush.theme.load()` are unavailable. Protected files
cannot import dependencies.

Theme sources are limited to 256 KiB, and each theme has an 8 MiB Lua memory
limit. Each file or builder call has a 500,000-instruction budget and checks a
250 ms deadline through Lua's hook. The deadline is best effort during C calls;
the Lua state remains inside Lush's process. Builder context/options and
returned descriptors cross as copied plain data, bounded to 4,096 nodes,
256 KiB, and 32 nesting levels. A builder error is reported and disables that
loaded builder until restart.

Interactive Lua, scripts, `init.lua`, normal `source()` calls, and builders
defined in your configuration retain the ordinary shell APIs. Loading a theme
with `source()` deliberately bypasses the file restrictions; use
`lush.theme.load()` for protected files.
Registering a value returned by `lush.theme.load()` keeps its protection.
Existing `init.lua` files are preserved. If yours sources every file in
`themes`, remove that loop to load only the selected, protected theme.

These are Lush adaptations of the original Oh My Posh
[powerlevel10k_classic](https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/powerlevel10k_classic.omp.json),
[easy-term](https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/easy-term.omp.json),
and [iterm2](https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/iterm2.omp.json)
themes. Source references are recorded in each external Lua file; attribution and
the MIT license are in [THIRD_PARTY_NOTICES](THIRD_PARTY_NOTICES).
The runtime embeds the component utilities. Theme definitions remain external,
and Oh My Posh is not required.

Icons and powerline glyphs work best with a Nerd Font. For ASCII symbols, set:

```lua
lush.config.theme_options = {icons = false, git = true, time = true}
```

Each component can also be switched off through `theme_options`: `os`, `path`,
`git`, `session`, `time`, `status`, `execution_time`, `python`, `battery`, `root`,
and `memory`. Missing optional information omits its segment and adjoining joins.
Colors use `#RGB` or `#RRGGBB` foregrounds and backgrounds.

A `lush.config.prompt` string or callback takes priority over `theme`. Remove
that assignment or set it to nil when selecting a theme. Existing prompt
callbacks remain supported:

```lua
lush.config.prompt = function() return pwd() .. " > " end
```

Build a custom named theme in the same `init.lua`:

```lua
local t = lush.theme
lush.config.themes = lush.config.themes or {}
lush.config.themes.custom = function(context, options)
    return t.prompt{
        rows = {t.row{
            left = {t.path{fg = "#26C6DA", suffix = " "},
                    t.git{fg = "#D4E157"}},
            right = {t.session{fg = "#D4E157", suffix = " "},
                     t.time{fg = "#26C6DA"}},
        }},
        input = {t.status{success_fg = "#D4E157", error_fg = "#FF5252", suffix = " "}},
    }
end
lush.config.theme = "custom"
```

Registry entries can hold descriptors directly, and `lush.config.theme` may
be a descriptor or builder function. A separate theme file can return the same
`t.prompt{...}` descriptor. `t.text(value, style)` adds fixed text;
`t.chain(components, options)` builds automatic powerline transitions.
`t.row{left=..., right=...}` creates a header, and `t.prompt{rows=..., input=...}`
supports up to four headers followed by the editable input prefix. The renderer
measures visible Unicode cell widths, preserves SGR colors, and strips cursor,
title, and other terminal controls from prompt content.

Available context components are `os`, `path`, `git`, `session`, `time`, `status`,
`execution_time`, `python`, `battery`, `root`, and `memory`. Context is collected
natively once for each new prompt. Git has a 200 ms deadline; absent or slow Git
information is omitted. Python information comes from the active environment,
and memory/battery data comes from the operating system. Lush does not launch
Node, PHP, npm, or other optional runtime version probes for its prompt.

Use the command help to inspect components and render sample contexts:

```lua
help("lush.theme")
help(lush.theme.load)
help(lush.theme.path)
help("lush.theme.chain")
help("lush.config.themes")
local descriptor = lush.theme.prompt{input = {lush.theme.path(), lush.theme.text(" > ")}}
lush.theme.render(descriptor, {cwd = "/work", home = "/home/me", platform = "linux"})
```

## Syntax highlighting

The prompt colors Lua keywords and literals, strings, numbers, comments,
function calls, and operators as you type. Long bracket strings and comments
retain their context across continuation lines. Highlighting reads tokens without
executing the input. It preserves the gray, dim history suggestion until you
accept it; accepted text receives its Lua syntax colors.

Highlighting is enabled by default on color-capable terminals. To disable it,
set this in `init.lua` and restart Lush:

```lua
lush.config.syntax_highlighting = false
```

Scripts, `-c`, and redirected input keep their existing output without prompt
highlighting. Existing configuration files need no changes to enable it.

## History and autosuggestions

Interactive sessions save complete Lua submissions to
`get_config_dir()/lush/history.jsonl`, beside the default configuration. History
loads when the interactive session starts and is saved before execution, including
commands that fail or call `exit()` or `os.exit()`. Blank input, cancelled input,
and unfinished Lua chunks are omitted. Consecutive duplicate submissions are
stored once. JSON strings preserve multiline input, quotes, and Unicode.

As you type, Lush shows the remainder of the most recent history entry matching
the input's exact, case-sensitive prefix. The suggestion appears in gray when the
input is nonempty and the caret is at its end. It is clipped to the available
width and is hidden while entering a multiline continuation.

- Press **Right** at the end to accept the full suggestion, then edit or submit it.
- Press **Enter** to run only the text you have typed; it does not accept a suggestion.
- Up/Down navigate history and restore your unfinished draft when you return to it.
- Moving the caret into the input keeps the normal editing behavior.

Only an interactive terminal reads or writes persistent history. `-c`, script
files, and piped stdin do not. A history I/O failure prints a warning and leaves
the shell usable with in-memory history.

Configure this behavior in `init.lua`:

```lua
lush.config.history_limit = 1000
lush.config.autosuggestions = true
lush.config.syntax_highlighting = true
-- lush.config.history_file = false  -- disable disk history, keeping session history
```

| Setting | Default | Accepted values |
| --- | --- | --- |
| `lush.config.history_file` | `get_config_dir()/lush/history.jsonl` | A path string; `false` or `""` disables disk history |
| `lush.config.history_limit` | `1000` | An integer from `0` to `100000`; `0` disables history entries |
| `lush.config.autosuggestions` | `true` | `true` or `false` |
| `lush.config.syntax_highlighting` | `true` | `true` or `false` |

An unset `history_file` uses `LUSH_HISTORY_FILE` when that environment variable is
present, including an empty value to disable persistence; otherwise it uses the
default path. An explicit Lua setting takes precedence. Relative history paths
are resolved against the startup working directory once, so `cd()` does not move
the history file. Windows drive paths must include a root (`D:/history.jsonl`,
rather than `D:history.jsonl`). `--no-config` skips loading Lua configuration while keeping the
default history behavior.

`history_limit` bounds the entries retained for navigation and suggestions. The
startup loader scans the newest 8 MiB of the log and skips encoded records larger
than 1 MiB. The JSONL file is currently append-only and is not compacted to the
entry limit. Settings are read at startup; restart Lush after editing them.

## fls listings and the takeoff animation

An unmodified `ls(...)` displayed at the prompt uses the actual `fls` renderer,
embedded from the sibling project's source. Its flags retain their meanings:

```lua
ls()
ls("-la")
ls("-T", "-L", "2", "--icons", ".")
ls("-l", "--git", "--color=always")
ls("--tui")
ls("--lol")                         -- fls's sl-style plane takeoff
sl()                                -- shortcut for ls("--lol")
```

These are standard Lua calls: `ls --lol` would begin a Lua comment. In a script,
use `show(ls("-la"))` or `show(sl())` to display a listing or run the animation.
`ls("--lol=signal")` allows interrupting the animation. Snapshot flags from `fls`
are also available, for example `show(sl("--snapshot", "-w", "80"))`.

On Windows, opening a file in `ls("--tui")` uses its default application through
the same native handler as `lush.open`. `FLS_OPENER` and `NNN_OPENER` override it.
Press `p` to copy selected entries into the current directory. During longer
copies and deletions, the bottom row shows progress and the current selection
number (for example, `3/8`). A long listing such as `ls("-l", "--total-size")`
shows how many entries it has scanned while it calculates directory sizes.

The same listing remains structured when collected or transformed:

```lua
show(ls("-a", "-s", "size"):select("name", "size"))
local files = ls("-f", "-I", "*.tmp"):collect()
```

In `where(function(f) ... end)`, `f` is one file record. Inspect its fields before
writing a callback:

```lua
help(ls)                       -- complete output fields, types, and meanings
ls():columns()                 -- fields present in this listing
ls():first(1)                  -- one sample record
ls():get("size")               -- extract the size values
show(lush.schemas.file)        -- shared file-field documentation metadata
```

| Field | Lua type | Meaning |
| --- | --- | --- |
| `name` | string | Entry name; an explicit file argument may retain its supplied path |
| `path` | string | Path used to access the entry |
| `type` | string | `file`, `dir`, `symlink`, `fifo`, `socket`, `block`, `character`, or `other` |
| `kind` | string | Alias of `type` |
| `size` | integer | Size in bytes; `--total-size` sums directory contents |
| `depth` | integer | Recursion depth, starting at zero |
| `modified` | integer, optional | Modification time in Unix seconds |
| `git` | string, optional | Two-character fls status with `--git` when repository metadata is available |
| `git_x`, `git_y` | integer, optional | Byte codes of the index and working-tree status characters |
| `link_target` | string, optional | Readable symbolic-link target text |

Use `where` for a keep/skip decision: return `true` to keep a record or `false`
to skip it. Returning `f.size` does not extract sizes, because Lua numbers are
truthy; use `get("size")`. `print()` returns nil, so use `foreach` for printing:

```lua
ls():where(function(f) return f.type == "file" and f.size > 1024 end)
ls():foreach(function(f) print(f.name, f.size) end)
```

Record selection and sorting use the same `fls` options as the displayed view.
Applying transforms renders the resulting records as a table. Animation, TUI,
help and version modes are display-only and cannot be collected as records.
The source snapshot and its small embedding adaptations are described in
[`vendor/fls/README.md`](vendor/fls/README.md); no external `fls` executable is needed.

## Builtins and command help

Discover commands with Nushell-style help, using Lua calls:

```lua
help()                         -- overview and starting points
help("lush")                   -- namespace, configuration, and API members
help("commands")               -- searchable, structured command catalog
help("commands", "file")       -- filter names and descriptions
help("ls")                     -- usage, options, parameters, types, examples
help(ls)                       -- function references and their aliases also work
help(lush.ls)
help(version())                -- actual fields and types of a returned table
help(stat("."))
help("path.join")
commands("table"):select("name", "description")
```

Tab completes command names inside `help("...")`. Command help uses Nushell's
[help layout](https://www.nushell.sh/commands/docs/help.html); the builtin set draws
on [fish's tools](https://fishshell.com/docs/current/commands.html) and
[Nushell's structured filters](https://www.nushell.sh/commands/categories/filters.html).
Lua's existing functions, variables, `string`, `math`, and `table` libraries remain
available for programming.

Pass any returned table to `help(value)` to inspect its current fields and types.
Nested paths include array indices, such as `files[1].name`; integers and floats
are distinguished. Inspection reads stored fields without calling metamethods,
evaluating streams, or running command plans. Cycles and shared tables are marked
as references. Large/deep tables and long keys are bounded, with omissions marked.
Only present fields appear; use `help(stat)` for its complete documented schema,
including optional fields. To inspect actual stream items, collect a sample:

```lua
help(ls():first(1):collect())
help(json.decode('{"items":[{"name":"report","size":42}]}'))
```

Help includes typed **Output fields** for builtins with a known record shape:

```lua
help(stat)
help(version)
help(commands)                 -- detailed catalog fields; help("commands") returns the catalog
help(capture)
help(enumerate)
help(lush.theme.prompt)
help(lush.theme.render)
```

| Producer | Known output fields |
| --- | --- |
| `stat(path)` | `path`, `name`, `type`, `size`, optional `modified` |
| `version()` | `name`, `version`, `lua`, `platform` |
| `commands()`, `help("commands")`, `help("find", query)` | Rows with `name`, `category`, `description` |
| `run()`, `capture()`, `Exec:run()`, `Exec:capture()`, `Result:check()` | `ok`, `code`, `signal`, `stdout`, `stderr`, `statuses[]` |
| `cmd.program(...)`, `cmd(program, ...)` | Lazy plan with `commands[][]` and optional input bytes |
| `flow:enumerate()` | `index` and the original, data-dependent `item` |
| `lush.theme` component constructors | Descriptor `kind` and the component's documented style/value/child fields |
| `lush.theme.row()` and `lush.theme.prompt()` | Header/component arrays with their nested descriptor fields |
| `lush.theme.render()` | `lines[].left`, `lines[].right`, and `input` strings |

In nested field paths, `.` selects a record member and `[]` describes an array
item. Optional fields may be absent. A captured process result's `statuses[]`
contains stage exit codes; inherited-terminal `run()` leaves `stdout` and
`stderr` empty, and launch failures raise Lua errors.

The shared `lush.schemas` metadata supplies field names, types, meanings, and
nested shapes to help and completion. `lush.schemas.producers` describes each
documented producer's output kind, with `fields` for records and `items` for
arrays/streams. For example, `lush.schemas.result` documents process results.

Input-dependent operations such as `stream`, `map`, `select`, `collect`, `source`,
and JSON decoding are labeled **Data-dependent**. Their input or callback decides
the fields. For a record stream, inspect `value:columns()` or `value:first(1)`;
inspect decoded scalar/list values directly. Enumerated records always have
`index` and `item`, while the fields inside `item` follow the original data.

In filesystem commands, `~` means `%USERPROFILE%` on Windows and `$HOME` on
POSIX. Use `~/` on either platform. Windows also accepts a backslash after the
tilde. Only a leading `~` component expands, so `~draft` is a regular filename
and `./~` addresses an entry named `~` in the current directory.

```lua
mkdir("work/output")
touch("work/output/notes.txt")
cp("notes.txt", "backup.txt")
mv("backup.txt", "~/renamed.txt")
rm("~/renamed.txt")
stat("notes.txt")
exists("notes.txt")
path.join("work", "notes.txt")
path.basename("work/notes.txt")
path.expand("~/work")
```

`cd()` and `cd("~")` both go home. To pass a home-relative path as an argument
to an external program, use `path.expand`, for example
`cmd.git("-C", path.expand("~/work"), "status")`.

Copy and move use the exact destination path and refuse to overwrite existing
files by default. Set `{overwrite=true}` explicitly to replace them. When stderr
is a terminal, copies lasting about 250 ms or longer show the percentage of
bytes copied across the file or directory tree. On Windows, recursive copies
start transferring files while counting the total. The display shows bytes
transferred, a percentage, and the completed entry count when space permits.
If files differ only by case, Lush tries
to enable case sensitivity on the corresponding new directory. If Windows
refuses, the error names the conflicting entries before either is written in
that directory. Recursive deletion reports the number of entries removed after
the same delay. Copying a directory or
deleting a nonempty directory requires `{recursive=true}`. A directory copy
with both options merges into the destination tree. `rm` deletes directly;
it does not move files to a recycle bin. `touch` preserves existing contents.
The `path` table also provides `dirname`, `stem`, `extension`, `normalize`, and
`exists`.

More structured operations work as methods or pipeline stages:

```lua
ls():reject("modified"):rename("name", "filename"):first(5)
stream({3, 1, 3, 2}):uniq():reverse():enumerate()
stream({{a=1}, {a=json.null}}):default("a", 0):update("a", function(x) return x * 2 end)
stream({1, 2, 3}):reduce(function(total, x) return total + x end, 0)
stream({1, 2, 3}) | any(function(x) return x > 2 end)
```

Additional transforms include `last`, `flatten`, `append`, `prepend`, `columns`,
and `all`. `first` and `last` keep a stream even when returning one row.

`source("setup.lua", ...)` runs Lua in the current global context and returns the
chunk's values. `which("git")` finds an executable in `PATH`; `describe(value)`
describes a Lua or shell value. `contains(list, item)`, `printf(format, ...)`,
`version()`, and `clear()` cover common shell tasks. `clear()` requires a terminal.

## External commands

`cmd` is a Lua table with an `__index` metamethod. Looking up `cmd.git` creates a
callable command builder for the executable `git`. It does not require a registry
of executable names.

```lua
local status = cmd.git("status", "--short")  -- construct; no process starts yet
run(status)                                -- inherit stdin/stdout/stderr
local result = capture(status)              -- capture stdout and stderr as bytes
print(result.stdout)
print(result.ok, result.code)
result:check()                              -- raise if the exit was unsuccessful

cmd["my-tool"]("--help")                    -- names with punctuation
cmd["C:/tools/tool.exe"]("a file.txt")       -- explicit executable paths
run{"git", "status"}                       -- an argv array is also accepted
```

Arguments are passed separately through Glosso's process API. Spaces, quotes,
wildcards, `$`, and semicolons inside an argument remain data. There is no implicit
word splitting, glob expansion, or command-string evaluation. Numbers are
converted to strings; nil, sparse argument arrays, and embedded NUL are rejected.
On Windows, `.cmd` and `.bat` use Glosso's explicit batch-file launch support.

Nonzero process exits are ordinary results with `ok = false`. Launch failures and
`:check()` failures raise Lua errors. Results include `code`, `signal`, `stdout`,
`stderr`, and `statuses` (one exit code per pipeline stage). `lush.last_status`
tracks the most recently executed external pipeline in a submission; successful
Lua-only submissions reset it to zero. It supplies the shell's exit status unless
`exit(code)` overrides it, and `exit()` uses the previous status. Lua errors exit with status 1 in
noninteractive mode. Use `result.ok`, since Lua treats zero and tables as truthy.

## Pipelines and structured data

Lua's existing `|` operator is overloaded for command and pipeline objects.
Integer bitwise operations retain their normal meaning. Method chains and
`pipe(...)` provide equivalent composition without operator syntax.

```lua
-- External-to-external stages run concurrently, connected by operating-system pipes.
local log = cmd.git("log", "--oneline") | cmd.head("-n", "5")
run(log)

-- Explicit byte-to-value conversion.
show(cmd.git("log", "--oneline") | lines() | take(5))

-- Filesystem records remain Lua values until explicitly encoded.
local large = ls():where(function(f) return f.size > 1024 end)
show(large:select("name", "size"))
show(large | to.json() | save("large-files.json"))

-- JSON null and empty-object/array identity survive parsing and encoding.
local data = json.decode(cat("large-files.json"))
show(stream(data):get("name"))
print(json.encode(json.object()))
```

Lua requires an expression to be used in a valid statement in script files:
assign a pipeline to a variable, pass it to `show`, or call `run` to execute it.
An expression alone is a prompt convenience, matching Lua REPL behavior.

Transforms include `where`/`filter`, `select`, `get`, `map`/`each`, `take`, `skip`,
`sort_by`, `lines`, `count`, `collect`, `to_json`, and `from_json`.
`each` maps values lazily; `foreach` immediately invokes a callback for each value.
`ls(...):collect()` returns records containing `name`, `path`, `type`, `kind`, `size`,
`depth`, and, when available, `modified` as Unix seconds. Git status is included
with `--git`. The original `ls(path, all)` form is retained; `all = true` includes
hidden entries. Listing order follows `fls`'s natural name sorting by default.

External pipelines use rightmost-nonzero `pipefail`; every stage's status remains
available. This includes an upstream broken-pipe failure when a downstream program
exits early. Capture uses private temporary files for stdout/stderr so large
simultaneous output cannot deadlock a full capture pipe. Captured stderr from all
stages shares one output stream; its ordering is determined by the programs.

Structured transforms are lazy to construct but currently collect arrays when
evaluated. Byte adapters and captured output also collect their result in memory.
They do not yet provide bounded streaming or backpressure for Lua records.

## Scripts and configuration

```sh
lush --help
lush -c 'ls():select("name", "size")'
lush tasks.lua argument
lush --no-config tasks.lua
lush --config ./init.lua
```

Scripts use `arg[0]` for their path and `arg[1]` onward for arguments. Script return
values are not auto-displayed. The shell API is available as globals and through
`require("lush")` (for example, `lush.run`, `lush.capture`, and `lush.json`).

Configuration is ordinary Lua, loaded before a command, script, or REPL:

```lua
lush.config.prompt = function() return pwd() .. " > " end
lush.config.history_limit = 1000
lush.config.autosuggestions = true
function gst() return cmd.git("status", "--short") end
```

The configuration path is chosen in this order:

1. `--config PATH`.
2. `LUSH_CONFIG`.
3. `get_config_dir()/lush/init.lua`, using Glosso's
   [`get_config_dir()`](../glosso/std/File_System/Directory_Paths.glo).

Glosso obtains the Windows Roaming AppData Known Folder and uses an absolute
`XDG_CONFIG_HOME` or `$HOME/.config` on Linux. Configuration and the default
history file share the `lush` subdirectory of that platform directory. Lush
creates a missing default `init.lua` with the default prompt, history limit, and
autosuggestion settings. Edit that file to customize future sessions. Existing
configuration is preserved. [`config.example.lua`](config.example.lua) includes
additional examples you can copy into it or select with `--config`.

Automatic creation applies only when the default path is selected. `--config`
and `LUSH_CONFIG` never create their selected file; a missing or invalid explicit
configuration is an error. If the default file cannot be created, Lush warns and
continues with its built-in defaults. Errors in an existing configuration remain
errors. `--no-config` skips loading and creation and cannot be combined with
`--config`.

`pwd()` returns the current working directory with forward slash (`/`) separators,
including on Windows. `cd(path)` and `env.NAME = "value"` update the parent shell session.
Assigning nil to `env.NAME` removes the environment variable. Children inherit
that directory and environment. `cat(path)` or `lush.read(path)` reads bytes;
`lush.write(path, bytes, append)` writes bytes. On Windows, `open(target)` opens
a file, folder, or URL with its default application. It returns true when the
launch request is accepted, without waiting for the application to exit, and
raises a Lua error on failure. Pass the target as one nonempty string.
`help()` describes the available library.

```lua
local contents = cat("README.md")
open("README.md") -- Windows: open in the associated application
open(".")         -- Windows: open the current directory
open("https://example.com")
```

## Aliases

Register aliases in `init.lua` or `get_config_dir()/lush/aliases.lua`. The
default `init.lua` loads `aliases.lua` when it exists. For an existing
configuration, load that file with `source(path.join(lush.config_dir,
"aliases.lua"))`.

```lua
alias("s", ls)
alias("gst", {"git", "status", "--short"})
alias({c = clear, gco = {"git", "checkout"}})
```

Names are ASCII Lua identifiers; Lua keywords, `_G`, and `lush` are reserved.
Registrations may replace existing globals. Function aliases export the same
function object. Command aliases copy a nonempty argument prefix and append
call arguments literally, without shell splitting. Prefix arrays must be dense;
strings and numbers are accepted, numbers become strings, and NUL is rejected.
A bulk registration validates the entire map before applying it.

Use normal Lua calls with parentheses:

```lua
s()
gco("main")
gst()       -- At the prompt, the returned command plan executes automatically.
run(gst())  -- Scripts execute returned command plans explicitly.
```

A local function in a sourced file keeps its normal Lua scope. Export it with
`alias()` so later prompt submissions can call it:

```lua
local function largest(limit)
    return ls():sort_by("size", true):take(limit or 5)
end
alias("largest", largest)

alias("glog", function(...)
    return cmd.git("log", "--oneline", ...)
end)
```

Return the value or command plan from a wrapper. Constructing a plan alone
does not execute it. `_G.largest = largest` also exports a local function;
`alias()` additionally registers its discovery metadata.

`aliases()` returns a sorted array of active `{name, kind, command?}` records;
external entries include a copied argument prefix. Replacing a registered
global through ordinary Lua assignment removes it from this active catalog.
`commands()` and `help("name")` reflect registrations immediately.
`help("s")` describes the alias, while `help(s)` retains `help(ls)` because the
functions have the same identity. Discovery never calls an alias function.
The same registration and catalog functions are available as `lush.alias` and
`lush.aliases`.

## Tests and organization

```sh
python tests/integration.py --exe build/lush.exe
python tests/open.py --exe build/lush.exe             # Windows app handoff and binary cat reads
build/lush.exe --no-config tests/library.lua
build/lush.exe --no-config tests/completion.lua
build/lush.exe --no-config tests/highlight.lua
build/lush.exe --no-config tests/data.lua
build/lush.exe --no-config tests/help.lua
build/lush.exe --no-config tests/help_values.lua
build/lush.exe --no-config tests/theme.lua
python tests/filesystem.py --exe build/lush.exe
python tests/shell.py --exe build/lush.exe
python tests/fls.py --exe build/lush.exe
python tests/windows_console.py --exe build/lush.exe  # Windows native console
python tests/tui_cursor.py --exe build/lush.exe       # ConPTY cursor paint ordering
python tests/tui_open.py --exe build/lush.exe         # Windows browser opener and navigation
python tests/repl_cursor.py --exe build/lush.exe      # Prompt redraws and unchanged keys
python tests/history.py --exe build/lush.exe          # Persistence and history suggestions
python tests/highlighting.py --exe build/lush.exe     # Lua input colors and caret behavior
python tests/themes.py --exe build/lush.exe           # External themes, builders, colors and layout
python tests/repl_resize.py --exe build/lush.exe      # Real ConPTY cells after zoom-like resizes
python tests/theme_config.py --exe build/lush.exe     # Selected-only loading and caching
python tests/theme_sandbox.py --exe build/lush.exe    # Theme capabilities, isolation and quotas
```

The integration suite exercises the actual executable, including Lua semantics,
multiline stdin, configuration, structured records and JSON, exact argv passing,
binary input/output, concurrent pipelines exceeding pipe-buffer capacity, and
cleanup after a failed launch.

| Path | Responsibility |
| --- | --- |
| `first.glo` | Compile-time build script |
| `main.glo` | Options, configuration, scripts, session startup |
| `src/configuration.glo` | Default configuration creation without replacing existing files |
| `src/default_init.lua` | Embedded initial user configuration |
| `src/theme_sandbox.lua` | Safe theme environment and bounded Lua utility wrappers |
| `src/theme_vm.glo`, `src/theme_vm.c` | Glosso binding and Lua C API bridge for isolated theme states and quotas |
| `src/lua.glo` | Minimal Lua C API declarations and static runtime linkage |
| `src/runtime.glo` | Embedded library, protected evaluation, Lua session |
| `src/native.glo` | Filesystem/environment callbacks and Lua value conversion |
| `src/opener.glo` | Windows default-application handoff for literal files, folders and URLs |
| `src/executables.glo` | PATH and executable discovery for completion |
| `src/completion.lua` | Lua-aware executable, path, and name completion |
| `src/highlight.lua` | Lua token colors, including incomplete input |
| `src/highlighting.glo` | Protected highlight hook and validated terminal palette |
| `src/filesystem.glo` | Native filesystem operations and platform path helpers |
| `src/filesystem.lua` | Lua filesystem builtins and option validation |
| `src/records.lua` | Shared producer output metadata and nested record fields for help and completion |
| `src/data.lua` | Additional structured stream and record transforms |
| `src/shell.lua` | Source loading, discovery, value inspection, shell utilities |
| `src/help.lua` | Searchable command catalog and detailed command help |
| `src/theme.lua` | Reusable prompt components and rendering utilities |
| `themes/` | External Lua prompt definitions built from those components |
| `src/prompt_context.glo` | Native prompt facts and bounded Git context |
| `src/fls.glo` | Embedded fls dispatch and structured record adapter |
| `vendor/fls/` | fls renderer, options, TUI, and animation source snapshot |
| `src/process.glo` | Concurrent external pipelines, capture, process cleanup |
| `src/repl.glo` | Terminal editor, history, completion, multiline input |
| `src/repl_layout.glo` | Native geometry and active-prompt recovery after terminal reflow |
| `src/history.glo` | Locked JSONL persistence and bounded history loading |
| `src/history_settings.glo` | Lua editor/history settings and stable path resolution |
| `src/screen.glo` | Hide/paint/position/show ordering for interactive canvases |
| `src/bootstrap.lua` | Lua shell API, structured transforms, JSON, display |

This is an initial usable implementation. Asynchronous background jobs,
cancellation of running Lua, and Unix
foreground process-group/stop/resume job control are not implemented yet. It is
not ready to replace a login shell. Shell input, scripts and init.lua execute
with the user's normal filesystem and process access, like ordinary shell
scripts; named theme files use the restricted theme VM described above.
