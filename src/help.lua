-- Command discovery and structured, Lua-oriented help.
-- Alias registration may replace globals; discovery keeps its own helpers.
local assert, error, getmetatable, ipairs, next, pairs, rawequal, rawget, tostring, type =
    assert, error, getmetatable, ipairs, next, pairs, rawequal, rawget, tostring, type
local math, string, table, utf8, stream = math, string, table, utf8, stream
local active_aliases = rawget(lush, "aliases")
local registry, by_name, by_function = {}, {}, {}
local function add(name, category, description, details)
    details = details or {}
    details.name, details.category, details.description = name, category, description
    details.usage = details.usage or name .. "()"
    details.parameters, details.flags = details.parameters or {}, details.flags or {}
    details.input, details.output = details.input or "nothing", details.output or "nil"
    details.examples, details.notes = details.examples or {}, details.notes or ""
    assert(not by_name[name], "duplicate help entry: " .. name)
    registry[#registry + 1], by_name[name] = details, details
end
local function alias(name, target, usage)
    local original = assert(by_name[target], "missing help alias target: " .. target)
    local details = {}
    for key, value in pairs(original) do details[key] = value end
    details.usage, details.alias_for = usage or original.usage, target
    details.notes = "Alias for " .. target .. ". " .. original.notes
    add(name, original.category, original.description, details)
end

add("help", "Shell", "Show command documentation, inspect table fields, or search the command catalog.", {
    usage = "help(topic?, query?)", output = "string, or Flow<record> for command searches",
    parameters = {"topic: optional command name, documented function, or table to inspect; lush shows namespace help; 'commands' lists commands; 'find' searches.", "query: search text for 'commands' or 'find'."},
    examples = {"help()", "help('lush')", "help(lush)", "help('ls')", "help(ls)", "help(lush.ls)", "help(version())", "help(stat('.'))", "help('commands', 'copy')", "help('find', 'json')"},
    notes = "Function references resolve by identity, including aliases of documented functions. Shared aliases use their canonical topic. Function help never executes the supplied function. Table help shows actual stored fields and nested types, without calling metamethods or evaluating lazy streams/commands. Inspection is bounded and marks omitted fields or repeated references; absent and inherited fields are not included.",
})
add("commands", "Shell", "List Lush commands as searchable name, category, and description records.", {
    usage = "commands(query?) / lush.commands(query?)", output = "Flow<{name, category, description}>",
    parameters = {"query: optional literal substring, matched without regard to case in names and descriptions."},
    examples = {"commands()", "commands('table'):select('name', 'description')"},
    notes = "Includes active aliases registered after startup. An active alias replaces the same name's builtin catalog row.",
})
add("alias", "Shell", "Register a callable global alias for a Lua function or external-command prefix.", {
    usage = "alias(name, function_or_argv) / alias({name = function_or_argv, ...})", output = "nil",
    parameters = {"name: ASCII Lua identifier; keywords, _G, and lush are reserved.",
                  "function_or_argv: function, or nonempty array of command/argument strings or numbers (numbers become strings).",
                  "mapping: optional table registering several names together."},
    examples = {"alias('s', ls)", "alias('gst', {'git', 'status', '--short'})",
                "alias({s = ls, c = clear, gst = {'git', 'status', '--short'}})"},
    notes = "Function aliases export the same function object, including local functions. Command prefixes are copied and create lazy command plans; extra call arguments are appended literally. Prefix arrays must be dense, the executable must be nonempty, and NUL is rejected. A bulk map is validated before any registration is applied. Call aliases with parentheses, such as s() and gst(). Function wrappers must return their values or command plan. The prompt displays/executes a returned plan; scripts use run(gst()). Put registrations in init.lua or its aliases.lua. Direct _G.name = local_function also exports a local function, while alias() registers discovery metadata. Existing globals may be replaced; lush.alias remains available if the global alias function is replaced.",
})
add("aliases", "Shell", "List the currently active registered aliases.", {
    usage = "aliases() / lush.aliases()", output = "sorted array of {name, kind, command?} records",
    examples = {"aliases()", "show(stream(aliases()):select('name', 'kind'))"},
    notes = "kind is 'function' or 'external'; command is a copied argument-prefix array for external aliases. Each call returns a fresh snapshot. A registration is active while its global still holds the registered function. Normal Lua assignments that replace it remove that name from this catalog. commands() and help() include active registrations without executing them.",
})
add("source", "Shell", "Execute a Lua file in this shell and return its chunk's values.", {
    usage = "source(path, ...)", output = "the values returned by the Lua chunk",
    parameters = {"path: Lua source file.", "...: arguments available through ... inside the file."},
    examples = {"source('init.lua')", "local value = source('settings.lua', 'development')"},
    notes = "Globals and shell state persist. Local variables retain ordinary Lua scope. BOM and shebang lines are supported.",
})
add("which", "Shell", "Locate an external executable using the current PATH.", {
    usage = "which(name)", output = "absolute path string, or nil when no executable is found",
    parameters = {"name: external executable name or path."}, examples = {"which('git')"},
    notes = "Looks up external programs. Lush functions are listed by commands().",
})
add("describe", "Shell", "Describe a Lua value or a Lush stream, command, or result.", {
    usage = "describe(value)", output = "type name string", parameters = {"value: any Lua value."},
    examples = {"describe(ls())", "describe({name = 'report'})", "describe(42)"},
})
add("version", "Shell", "Return Lush, Lua, and platform version information.", {
    output = "record with name, version, lua, and platform", examples = {"version()"},
})
add("clear", "Shell", "Clear the interactive terminal screen.", {
    examples = {"clear()"}, notes = "Requires an interactive terminal. Ctrl+L clears the screen while retaining the current edit.",
})
add("exit", "Shell", "Leave the shell with an exit status.", {
    usage = "exit(code?)", parameters = {"code: integer from 0 to 255; defaults to the previous command status."},
    examples = {"exit()", "exit(0)"}, notes = "Unwinds Lua execution so normal shell cleanup can run.",
})
add("contains", "Data", "Test whether a list or stream contains a value using Lua equality.", {
    usage = "contains(values, item)", input = "list or Flow", output = "boolean",
    parameters = {"values: list or structured stream.", "item: value to find; tables compare by identity."},
    examples = {"contains({1, 2, 3}, 2)"},
})
add("echo", "Display", "Print values separated by spaces and finish with a newline.", {
    usage = "echo(...)", parameters = {"...: values converted with tostring."}, examples = {"echo('hello', 'world')"},
})
add("printf", "Display", "Format and print values without an implicit newline.", {
    usage = "printf(format, ...)", parameters = {"format: Lua string.format format string.", "...: format arguments."},
    examples = {"printf('%s: %d\\n', 'files', 3)"},
})
add("show", "Display", "Display a value, render a table, or execute a command plan.", {
    usage = "show(value) / lush.display(value)", input = "any value", parameters = {"value: value, Flow, Exec, or Result to display."},
    examples = {"show(ls('-la'))", "show(stream{{name = 'report', size = 42}})"},
    notes = "The prompt displays expression results automatically. Scripts use show() explicitly.",
})

add("ls", "Filesystem", "List files as structured records or display the embedded fls view.", {
    usage = "ls(...flags_and_paths) / ls(path?, all?)", output = "Flow<file record>; an untransformed displayed result uses fls",
    parameters = {"...flags_and_paths: literal strings containing fls flags and paths.", "path, all: alternate directory and boolean hidden-file arguments."},
    flags = {"'-a', '--all': include hidden entries; '-A' excludes . and ...", "'-l', '--long': display a detailed table.",
             "'-1', '--oneline' / '-G', '--grid': choose line or grid display.", "'-T', '--tree' / '-R', '--recurse': recursive views.",
             "'-L', '--level', depth: limit recursion depth.", "'-D', '--only-dirs' / '-f', '--only-files': filter file kinds.",
             "'-s', '--sort', field / '-r', '--reverse': choose sorting.", "'-I', '--ignore-glob', patterns: exclude matching names.",
             "'--group-directories-first' / '--group-directories-last': group entries.", "'--git': display Git status.",
             "'--total-size': sum directory contents. Slow interactive size scans show how many entries have been visited.",
             "'--icons=WHEN', '--color=WHEN': always, auto, or never.", "'--tui': open the interactive browser.",
             "'--lol': play the takeoff animation; '--lol=signal' permits Ctrl+C.", "'--snapshot', '-w', columns: render a browser or animation snapshot.",
             "'--': subsequent strings are paths, including names beginning with '-'."},
    examples = {"ls()", "ls('-la', '.')", "ls():columns()", "ls():first(1)",
                "ls():where(function(f) return f.type == 'file' end):select('name', 'size')",
                "ls():get('size')", "ls():foreach(function(f) print(f.size) end)", "ls('--tui')"},
    notes = "In a callback such as where(function(f) ... end), f is one file record with the fields above. Return true to keep it or false to skip it. print() returns nil; use foreach(function(f) print(f.size) end) for printing, or get('size') to extract sizes. columns() discovers fields present in the current results; first(1) shows a sample record. Untransformed display uses fls formatting. Transforming or collecting yields records. Use show(ls('--help')) for the complete fls flag reference. A leading ~ path component expands to your home directory. Wildcard expansion is explicit.",
})
add("sl", "Display", "Play the embedded fls airplane takeoff animation.", {
    usage = "sl(...flags)", output = "display-only Flow", parameters = {"...flags: optional fls animation/display flags."},
    flags = {"'--lol=signal': allow interruption with Ctrl+C.", "'--snapshot', '-w', columns: produce a text snapshot."},
    examples = {"sl()", "show(sl('--lol=signal'))", "show(sl('--snapshot', '-w', '80'))"},
    notes = "Equivalent to ls('--lol', ...). Live animation needs an interactive terminal.",
})
add("pwd", "Filesystem", "Return the current working directory with forward slash separators.", {output = "path string", examples = {"pwd()"}})
add("cd", "Filesystem", "Change the shell's working directory.", {
    usage = "cd(path?)", parameters = {"path: directory. Omit it or use '~' for %USERPROFILE% on Windows or $HOME on POSIX."},
    examples = {"cd('src')", "cd('~/work')", "cd()"},
})
add("cat", "Filesystem", "Read a file's bytes into a Lua string.", {
    usage = "cat(path)", output = "byte string", parameters = {"path: file to read."},
    examples = {"cat('README.md')", "from.json(cat('settings.json'))"},
    notes = "Returns the raw bytes without decoding. Also available as lush.cat(path) and lush.read(path).",
})
add("open", "Filesystem", "Open a file, folder, or URL with its Windows default application.", {
    usage = "open(target)", output = "true when Windows accepts the launch request",
    parameters = {"target: nonempty file path, directory path, or URL without NUL bytes."},
    examples = {"open('README.md')", "open('.')", "open('https://example.com')"},
    notes = "Windows only. Dispatches one target through its registered association and returns without waiting for the application to exit. Launch failures raise Lua errors. Use cat(path) or lush.read(path) to read file bytes.",
})
add("save", "Filesystem", "Create a pipeline stage that writes bytes to a file.", {
    usage = "save(path, append?)", input = "byte string, command output, or explicitly encoded data", output = "Stage; its execution returns nil",
    parameters = {"path: destination file.", "append: boolean; true appends, false or omitted replaces contents."},
    examples = {"show(stream{{name = 'report'}} | to.json() | save('report.json'))"},
    notes = "Encode records with to.json() and scalar lists with to.text() before writing.",
})
add("mkdir", "Filesystem", "Create a directory and, by default, its missing parents.", {
    usage = "mkdir(path, options?)", output = "true", parameters = {"path: directory to create.", "options: Lua option table."},
    flags = {"{parents = true}: create missing parent directories (default true)."}, examples = {"mkdir('reports/2026')"},
})
add("touch", "Filesystem", "Create an absent file or update its modification time without changing contents.", {
    usage = "touch(path)", output = "true", parameters = {"path: file to create or update."}, examples = {"touch('notes.txt')"},
})
for _, item in ipairs({{"cp", "Copy a file or directory to an exact destination.", "recursive"},
                       {"mv", "Move or rename a file or directory to an exact destination."}}) do
    add(item[1], "Filesystem", item[2], {
        usage = item[1] .. "(source, destination, options?)", output = "true",
        parameters = {"source: existing path.", "destination: exact target path; the source name is not appended.", "options: Lua option table."},
        flags = item[3] and {"{recursive = true}: copy a directory tree (default false).", "{overwrite = true}: permit replacing an existing destination (default false)."}
                        or {"{overwrite = true}: permit replacing an existing destination (default false)."},
        examples = {item[1] .. "('draft.txt', 'final.txt')"},
        notes = item[3] and "Longer copies show the percentage of bytes copied across the file or directory tree. Recursive copies preserve symbolic links. Existing tree merging requires overwrite = true."
                       or "Uses native rename semantics; cross-device and directory replacement limits depend on the platform.",
    })
end
add("rm", "Filesystem", "Remove a file or directory with explicit recursive and missing-path options.", {
    usage = "rm(path, options?)", output = "true", parameters = {"path: path to remove.", "options: Lua option table."},
    flags = {"{recursive = true}: remove a directory tree (default false).", "{force = true}: ignore an absent path (default false)."},
    examples = {"rm('temporary.txt')", "rm('cache', {recursive = true})"},
    notes = "Longer recursive deletions show the number of entries removed on terminal stderr.",
})
add("stat", "Filesystem", "Return metadata for a path.", {
    usage = "stat(path, follow?)", output = "record with path, name, type, size, and available modification time",
    parameters = {"path: entry to inspect.", "follow: follow the final symbolic link; defaults to true."},
    examples = {"stat('README.md')", "stat('link', false)"},
})
add("exists", "Filesystem", "Test whether a directory entry exists, including a dangling symbolic link.", {
    usage = "exists(path)", output = "boolean", parameters = {"path: entry to check."}, examples = {"exists('README.md')"},
})
add("lush.write", "Filesystem", "Write bytes directly to a file.", {
    usage = "lush.write(path, bytes, append?)", output = "true", parameters = {"path: destination.", "bytes: Lua byte string.", "append: optional boolean."},
    examples = {"lush.write('notes.txt', 'hello\\n')"},
})
alias("lush.read", "cat", "lush.read(path)")

add("path", "Paths", "Access functions for composing, inspecting, expanding, and normalizing paths.", {
    usage = "path.join(...) / path.dirname(value) / path.expand(value)", output = "path function table",
    examples = {"path.join('src', 'main.glo')", "path.expand('~')"},
})
local path_help = {
    {"join", "Join path components using the platform's path rules.", "path.join(...)", "...: path component strings.", "path.join('reports', 'year.json')"},
    {"dirname", "Return a path's parent component.", "path.dirname(value)", "value: path string.", "path.dirname('src/main.glo')"},
    {"basename", "Return a path's final component.", "path.basename(value)", "value: path string.", "path.basename('src/main.glo')"},
    {"stem", "Return the final component without its extension.", "path.stem(value)", "value: path string.", "path.stem('report.json')"},
    {"extension", "Return a file extension including its dot, or an empty string.", "path.extension(value)", "value: path string.", "path.extension('report.json')"},
    {"normalize", "Clean a path lexically without reading the filesystem.", "path.normalize(value)", "value: path string.", "path.normalize('src/../README.md')"},
    {"expand", "Expand home and environment references and return an absolute path.", "path.expand(value)", "value: path string.", "path.expand('~/reports')"},
}
for _, item in ipairs(path_help) do
    add("path." .. item[1], "Paths", item[2], {usage = item[3], output = "path string", parameters = {item[4]}, examples = {item[5]},
        notes = item[1] == "expand" and "Leading ~ expands home. Unix supports $NAME and ${NAME}; Windows supports %NAME%. Missing variables remain literal. Expansion does not run commands or expand wildcards." or ""})
end
alias("path.exists", "exists", "path.exists(value)")

add("stream", "Data", "Construct a structured stream from a list, record, or scalar.", {
    usage = "stream(values)", input = "list, record, or scalar", output = "Flow", parameters = {"values: a list becomes its items; a record or scalar becomes one item."},
    examples = {"stream{1, 2, 3}", "stream{{name = 'a'}, {name = 'b'}}"},
})
local data = {
    {"where", "Keep items for which a Lua predicate is truthy.", "predicate", "predicate(item, index): Lua callback.", "stream{1, 2, 3}:where(function(n) return n > 1 end)"},
    {"each", "Map items through a Lua function, omitting nil results.", "callback", "callback(item, index): Lua callback.", "stream{1, 2}:each(function(n) return n * 2 end)"},
    {"select", "Project records onto selected fields, representing missing fields as json.null.", "...fields", "...fields: field name strings.", "ls():select('name', 'size')"},
    {"get", "Extract one record field, using json.null for missing fields.", "field", "field: record field name.", "ls():get('name')"},
    {"take", "Keep at most the first n items.", "n", "n: nonnegative integer.", "ls():take(5)"},
    {"skip", "Skip the first n items.", "n", "n: nonnegative integer.", "stream{1, 2, 3}:skip(1)"},
    {"sort_by", "Sort items or a record field, preserving the order of equal keys.", "field?, descending?", "field: optional field name; descending: optional boolean.", "ls():sort_by('size', true)"},
    {"reverse", "Reverse the item order.", "", "No parameters.", "stream{1, 2, 3}:reverse()"},
    {"uniq", "Keep the first occurrence of each structurally equal value or field value.", "field?", "field: optional record field used for deduplication.", "stream{1, 2, 2, 3}:uniq()"},
    {"first", "Keep the first n items as a stream.", "n?", "n: nonnegative count; defaults to 1.", "ls():first()"},
    {"last", "Keep the final n items in their original order as a stream.", "n?", "n: nonnegative count; defaults to 1.", "ls():last(3)"},
    {"enumerate", "Attach indexes as records containing index and item.", "start?", "start: integer index origin; defaults to 0.", "stream{'a', 'b'}:enumerate()"},
    {"flatten", "Flatten one level of nested lists.", "", "No parameters.", "stream{{1, 2}, {3}}:flatten()"},
    {"append", "Append list or stream items, or a single scalar or record.", "values", "values: list, Flow, scalar, or record; use json.null for a null item.", "stream{1, 2}:append({3, 4})"},
    {"prepend", "Prepend list or stream items, or a single scalar or record.", "values", "values: list, Flow, scalar, or record; use json.null for a null item.", "stream{3}:prepend({1, 2})"},
    {"columns", "List unique record field names in sorted order.", "", "No parameters.", "ls():columns()"},
    {"reject", "Copy records while removing selected fields.", "...fields", "...fields: field name strings.", "ls():reject('modified')"},
    {"rename", "Copy records while renaming a field, rejecting destination collisions.", "old, new", "old, new: original and replacement field names.", "ls():rename('size', 'bytes')"},
    {"update", "Copy records while updating a field through a Lua callback.", "field, callback", "callback(value, index): receives json.null for a missing field; nil results become json.null.", "ls():update('size', function(n) return n * 2 end)"},
    {"default", "Fill a missing or null record field while retaining false and other values.", "field, value", "field: field name; value: required replacement value.", "stream{{name = 'a'}}:default('size', 0)"},
}
for _, item in ipairs(data) do
    add(item[1], "Data", item[2], {usage = item[1] .. "(" .. item[3] .. ") / flow:" .. item[1] .. "(" .. item[3] .. ")",
        input = "structured stream", output = "Flow (or a Stage when called as a pipeline factory)", parameters = {item[4]}, examples = {item[5]},
        notes = "A Flow method transforms its input. The global form creates a stage for Lua's | operator."})
end
alias("map", "each", "map(callback) / flow:map(callback)")
alias("filter", "where", "filter(predicate) / flow:filter(predicate)")
add("Flow.foreach", "Data", "Immediately visit stream items for side effects.", {
    usage = "flow:foreach(callback)", input = "structured stream", parameters = {"callback(item, index): Lua callback."},
    examples = {"stream{'a', 'b'}:foreach(function(value) print(value) end)"},
})
for _, name in ipairs({"any", "all"}) do
    add(name, "Data", name == "any" and "Test whether any item satisfies a predicate; empty input is false." or "Test whether every item satisfies a predicate; empty input is true.", {
        usage = name .. "(predicate) / flow:" .. name .. "(predicate)", input = "structured stream", output = "boolean (global form returns a Stage)",
        parameters = {"predicate(item, index): required Lua callback; ordinary Lua truthiness applies."},
        examples = {"stream{1, 2, 3}:" .. name .. "(function(n) return n > 1 end)"},
    })
end
add("reduce", "Data", "Fold stream items into an accumulator using a Lua callback.", {
    usage = "reduce(callback, initial) / flow:reduce(callback, initial)", input = "structured stream", output = "accumulator value (global form returns a Stage)",
    parameters = {"callback(accumulator, item, index): returns the next accumulator.", "initial: required starting value; explicit nil is allowed."},
    examples = {"stream{1, 2, 3}:reduce(function(total, n) return total + n end, 0)"},
})
for _, item in ipairs({{"collect", "Collect stream items into a Lua list.", "list"}, {"count", "Count stream items.", "integer"}}) do
    add(item[1], "Data", item[2], {usage = item[1] .. "(value?) / flow:" .. item[1] .. "()", input = "structured stream", output = item[3] .. " (no-argument global form returns a Stage)",
        parameters = {"value: optional structured input; omitted creates a pipeline stage."}, examples = {"ls():" .. item[1] .. "()"}})
end

add("from.lines", "Formats", "Split byte strings into lines, trimming line-ending carriage returns.", {
    usage = "from.lines(value?) / lines(value?)", input = "bytes or external command output", output = "Flow<string>; no argument creates a Stage",
    parameters = {"value: optional byte input."}, examples = {"cmd.git('log', '--oneline') | from.lines() | take(5)"},
})
alias("lines", "from.lines", "lines(value?) / flow:lines()")
alias("from_lines", "from.lines", "from_lines(value?)")
add("from.json", "Formats", "Decode JSON bytes into a structured stream.", {
    usage = "from.json(value?)", input = "JSON bytes or external command output", output = "Flow; no argument creates a Stage",
    parameters = {"value: optional JSON bytes."}, examples = {"from.json(cat('settings.json'))", "from.json('[1,2,3]'):collect()"},
})
alias("from_json", "from.json", "from_json(value?)")
add("to.json", "Formats", "Encode a value or structured stream as JSON bytes.", {
    usage = "to.json(value?)", input = "Lua value or structured stream", output = "JSON string; no argument creates a Stage",
    parameters = {"value: optional value; streams encode as lists."}, examples = {"stream{{name = 'report'}} | to.json()"},
})
alias("to_json", "to.json", "to_json(value?) / flow:to_json()")
add("to.text", "Formats", "Encode scalar stream items as newline-separated bytes.", {
    usage = "to.text(value?)", input = "scalar list, Flow, or byte string", output = "byte string; no argument creates a Stage",
    parameters = {"value: optional scalar input. An existing string passes through unchanged."},
    examples = {"stream{'one', 'two'} | to.text()"}, notes = "Records require an explicit encoding such as to.json().",
})
alias("to_text", "to.text", "to_text(value?)")
for _, item in ipairs({{"encode", "Encode a Lua value as a JSON string.", "json.encode(value)", "Lua value", "JSON string", "json.encode({name = 'report'})"},
                       {"decode", "Decode a JSON string into a Lua value.", "json.decode(bytes)", "JSON bytes", "Lua value", "json.decode('{\"name\":\"report\"}')"},
                       {"array", "Mark a Lua table as a JSON list, including an empty list.", "json.array(values?)", "optional list", "marked list", "json.encode(json.array{})"},
                       {"object", "Mark a Lua table as a JSON object, including an empty object.", "json.object(fields?)", "optional record", "marked record", "json.encode(json.object{})"}}) do
    add("json." .. item[1], "Formats", item[2], {usage = item[3], input = item[4], output = item[5], examples = {item[6]}})
end
add("json.null", "Formats", "Represent JSON null without dropping a Lua table field or list item.", {
    usage = "json.null / lush.null", output = "null sentinel", examples = {"json.encode({missing = json.null})"},
})

add("cmd", "Processes", "Construct an external command with separate literal arguments.", {
    usage = "cmd.program(...) / cmd['program-name'](...) / cmd(program, ...)", output = "lazy Exec command plan",
    parameters = {"program: executable name or path.", "...: argument strings or numbers, one value per argument."},
    examples = {"cmd.git('status', '--short')", "cmd['my-tool']('--version')"},
    notes = "A displayed Exec runs with terminal input/output. Use run() for explicit execution or capture() for bytes and status. Arguments are not interpreted as shell source.",
})
for _, item in ipairs({{"run", "Execute a command plan and inherit terminal input/output.", "run(cmd.git('status')):check()"},
                       {"capture", "Execute a command plan and capture stdout and stderr as bytes.", "local result = capture(cmd.git('status')); print(result.code, result.stdout)"}}) do
    add(item[1], "Processes", item[2], {usage = item[1] .. "(command_or_argv) / " .. item[1] .. "(program, ...)",
        input = "Exec plan or argument list", output = "Result with ok, code, signal, stdout, stderr, and per-stage statuses",
        parameters = {"command_or_argv: Exec or a list beginning with the executable.", "program, ...: alternate separate program and arguments."}, examples = {item[3]},
        notes = "Nonzero exit codes return ok = false. Launch failures raise an error. Call :check() to turn a nonzero exit into a Lua error. Pipelines retain each stage's status and use the rightmost nonzero code."})
end
add("pipe", "Processes", "Compose command plans or data stages without executing them.", {
    usage = "pipe{first, second, ...} / pipe(first, second, ...)", input = "commands, streams, or stages", output = "composed plan or value",
    parameters = {"stages: an ordered list or separate pipeline components."},
    examples = {"pipe{cmd.git('log', '--oneline'), cmd.head('-n', '5')}", "stream{1, 2, 3} | where(function(n) return n > 1 end)"},
})
add("lush.stage", "Data", "Create a custom pipeline stage from a Lua function.", {
    usage = "lush.stage(callback)", input = "pipeline value", output = "Stage", parameters = {"callback(input): returns the stage's output."},
    examples = {"stream{1, 2, 3} | lush.stage(function(input) return input:count() end)"},
})
alias("Exec.run", "run", "command:run()")
alias("Exec.capture", "capture", "command:capture(input_bytes?)")
alias("Exec.lines", "from.lines", "command:lines()")
alias("Exec.from_json", "from.json", "command:from_json()")
add("Result.check", "Processes", "Return a successful result or raise a Lua error for a failed command.", {
    usage = "result:check()", input = "Result", output = "the same Result", examples = {"capture(cmd.git('status')):check()"},
})
alias("Result.lines", "from.lines", "result:lines()")
alias("Result.from_json", "from.json", "result:from_json()")

add("env", "Configuration", "Read and update the environment inherited by external programs.", {
    usage = "env.NAME / env.NAME = value / env.NAME = nil", output = "string or nil on lookup",
    parameters = {"NAME: environment variable name.", "value: string; assigning nil unsets the variable."},
    examples = {"env.EDITOR = 'vim'", "print(env.PATH)"},
})
add("lush", "Shell", "Access the shell API, configuration, and command discovery through one Lua table.", {
    usage = "lush / require('lush')", output = "Lua namespace table",
    members = {
        "config: prompt, persistent history, autosuggestions, and syntax colors; see help('lush.config').",
        "last_status: latest external pipeline status; successful Lua-only submissions reset it to zero.",
        "help(topic?), commands(query?): documentation and searchable builtin commands; command_registry holds a metadata snapshot.",
        "alias(name, function_or_argv), alias(mapping), aliases(): register and discover active global aliases.",
        "cmd, run, capture, pipe: construct and execute external commands and pipelines.",
        "ls, pwd, cd, mkdir, touch, cp, mv, rm, stat, exists: filesystem builtin functions.",
        "cat(path), read(path), write(path, bytes, append?): direct file I/O; read is an alias for cat().",
        "open(target): open a file, folder, or URL with its Windows default application.",
        "path: platform-native path helpers; see help('path').",
        "stream, where, select, get, each, take, collect, and other transforms: the same functions available globally.",
        "data: additional transform factories, including uniq, reverse, update, any, all, and reduce.",
        "schemas: shared field metadata for file/stat records, results, command plans, themes, and other documented outputs.",
        "schemas.producers: output kinds and known fields for documented producers; input-dependent fields remain explicit.",
        "from_json, to_json, to_text, lines: conversion functions exposed directly on this table.",
        "json, null: JSON encoding/decoding and the null sentinel; null is json.null, distinct from Lua nil.",
        "env: the environment table inherited by child processes, shared with global env.",
        "stage(callback): construct a custom Lua pipeline stage.",
        "Flow, Exec, Result: shared metatables; construct stream values with stream() and command plans with cmd.",
        "source, which, describe, version, clear, printf, contains, echo, show, exit: shell utility functions.",
        "prompt(), complete(source), highlight(source): prompt, completion, and syntax-highlighting hooks.",
        "theme: reusable prompt components and rendering utilities; see help('lush.theme').",
        "config_dir: platform configuration directory for Lush; user theme files can live in its themes subdirectory.",
        "config.themes: user-owned names mapped to prompt descriptors or builders; see help('lush.config.themes').",
        "check, eval, display, dispatch: runtime parsing, evaluation, and value-display hooks.",
    },
    examples = {"local sh = require('lush'); sh.pwd()", "lush.ls():select('name', 'size')",
                "lush.config.autosuggestions = true", "lush.commands('json')", "help('lush.config')"},
    notes = "require('lush') returns this same table. Most builtins are available both globally and as lush.name. " ..
            "Call namespace functions with a dot, such as lush.ls(); use a colon for value methods, such as lush.ls():collect(). " ..
            "Use help('lush.run') or help('run') for a builtin's detailed documentation.",
})
add("lush.theme", "Themes", "Build colored prompt themes from reusable Lua components.", {
    usage = "lush.theme.component(style?) / lush.theme.prompt{rows = {...}, input = {...}}",
    output = "theme component and rendering namespace",
    members = {"load(name): load one named Lua theme file from lush.config_dir/themes, caching its return value.",
               "text(value, style?), separator(glyph?, style?): literal text and separators.",
               "os, path, git, session, time, status: common prompt segments.",
               "execution_time, python, battery, root, memory: optional context segments.",
               "chain(components, options?): automatic powerline joins between visible segments.",
               "row{left = {...}, right = {...}}: one header with right-aligned components.",
               "prompt{rows = {...}, input = {...}}: up to four headers and an input prefix.",
               "render(spec, context, options?), render_components(components, context, options?): render descriptors.",
               "sanitize(value): remove escape and control sequences from dynamic text."},
    examples = {"lush.theme.path{fg = '#26C6DA'}",
                "lush.config.theme = lush.theme.prompt{input = {lush.theme.path(), lush.theme.text(' > ')}}",
                "help(lush.theme.path)"},
    notes = "Components are plain Lua descriptors. A selected name first resolves through lush.config.themes, then loads only that name's file from lush.config_dir/themes. Named files and lush.theme.load() use a separate restricted Lua state with basic functions and the pure theme API. init.lua and builders defined there keep normal shell access.",
})
add("lush.theme.load", "Themes", "Load one external theme by its filename stem.", {
    usage = "lush.theme.load(name)", output = "prompt descriptor or builder; nil, message on failure",
    parameters = {"name: single filename stem within lush.config_dir/themes; omit .lua and path separators. Requires lush.config_dir."},
    examples = {"lush.config.theme = 'easy-term'", "lush.config.theme = assert(lush.theme.load('easy-term'))"},
    notes = "Loads only lush.config_dir/themes/<name>.lua without scanning its directory. The file has a separate restricted Lua state: Lua basics, private string/math/table/utf8 libraries, and pure lush.theme utilities except load. No shell, filesystem/process APIs, os/io/package/debug, code loaders, pcall/xpcall, or imports. _G refers only to that theme's globals; string patterns/dump are unavailable and string.find is literal-only. Limits: 256 KiB source, 8 MiB Lua memory, 500,000 instructions and a hook-checked 250 ms deadline per file/builder call; the deadline is best effort during C calls, within Lush's process. Context/options and descriptors cross as copied plain data, bounded to 4,096 nodes, 256 KiB, and 32 levels. Successes and failures are cached by configuration directory/name. Builders run per prompt; their file runs once. A builder error disables it until restart. Normal source() bypasses file restrictions. Restart after editing or adding a cached file.",
})
add("lush.config.themes", "Themes", "Register user-owned names for component-built prompts loaded from ordinary Lua files.", {
    usage = "lush.config.themes[name] = descriptor_or_builder / lush.config.theme = name",
    output = "optional user-owned table of prompt descriptors or builder functions",
    parameters = {"name: a name chosen by your configuration; 'plain' is reserved for the default path prompt.",
                  "descriptor_or_builder: a theme.prompt descriptor, or function(context, options) returning one."},
    examples = {"lush.config.themes = lush.config.themes or {}",
                "lush.config.themes.work = assert(lush.theme.load('easy-term'))",
                "lush.config.theme = 'work'"},
    notes = "A matching entry takes priority over the selected name's file in lush.config_dir/themes. A value returned by lush.theme.load() keeps its restricted Lua state when registered. Builders defined in init.lua or returned by normal source() retain full shell access. The default init.lua does not scan or eagerly load theme files. The component library contains no named theme definitions. Set lush.config.theme_options.icons = false for ASCII symbols.",
})
local component_styles = {
    "style: optional table with fg/bg as #RGB or #RRGGBB, bold/dim/underline booleans, prefix/suffix text, and component-specific options.",
}
add("lush.theme.text", "Themes", "Create a literal text component with optional foreground and background colors.", {
    usage = "lush.theme.text(value, style?)", output = "text component descriptor",
    parameters = {"value: string or finite number.", component_styles[1]},
    flags = {"ascii: replacement text when theme_options.icons is false."},
    examples = {"lush.theme.text('> ', {fg = '#00ffff', bold = true})"},
})
local theme_components = {
    {"os", "Show the operating system's name or icon.", "lush.theme.os{fg = '#26C6DA'}", "label: optional operating-system label; icon: false or a replacement glyph."},
    {"path", "Show the working directory with optional home shortening or a folder-only view.", "lush.theme.path{fg = '#26C6DA', mode = 'folder'}", "mode: 'full' or 'folder'; home_shorten: boolean; icon: optional boolean or glyph."},
    {"git", "Show available Git branch, dirty/staged, ahead/behind, and stash state.", "lush.theme.git{fg = '#D4E157', prefix = ' '}", "branch_limit: maximum branch characters; show_counts: boolean; dirty/ahead/behind/diverged fg/bg colors."},
    {"session", "Show the native user and host, or only the user name.", "lush.theme.session{user_only = true}", "user_only: boolean; defaults to user@host when both are available."},
    {"time", "Show the clock supplied by the native prompt context.", "lush.theme.time{fg = '#999999'}", "icon: optional boolean or clock glyph."},
    {"status", "Show the preceding command's success or failure state.", "lush.theme.status{success_fg = '#D4E157', error_fg = '#FF5252', suffix = ' '}", "success/error fg/bg and text; show_code: boolean; always = false hides success; ascii: fallback text."},
    {"execution_time", "Show the previous command's duration after a configurable threshold.", "lush.theme.execution_time{threshold_ms = 150}", "threshold_ms: minimum duration in milliseconds; defaults to 150."},
    {"python", "Show the active Python environment when one is available.", "lush.theme.python{fg = '#81ff91'}", "icon: optional boolean or glyph. Reads environment context without running Python."},
    {"battery", "Show available native battery percentage and charging state.", "lush.theme.battery{fg = '#242424', bg = '#FFCD58'}", "icon: optional boolean or glyph; unavailable battery data omits the segment."},
    {"root", "Show an indicator for an elevated or root shell.", "lush.theme.root{fg = '#FFD700'}", "label: ASCII indicator; icon: false or a replacement glyph."},
    {"memory", "Show available native memory usage.", "lush.theme.memory{fg = '#81ff91'}", "Uses memory facts supplied by the native context; unavailable data omits the segment."},
}
for _, item in ipairs(theme_components) do
    add("lush.theme." .. item[1], "Themes", item[2], {
        usage = "lush.theme." .. item[1] .. "(style?)", output = "component descriptor",
        parameters = component_styles, flags = {item[4]}, examples = {item[3]},
        notes = "The descriptor reads context when rendered. Disabled optional components are omitted before separators are joined.",
    })
end
add("lush.theme.separator", "Themes", "Create a styled literal separator component.", {
    usage = "lush.theme.separator(glyph?, style?)", output = "text component descriptor",
    parameters = {"glyph: separator text; defaults to the powerline right separator.", component_styles[1]},
    examples = {"lush.theme.separator(' | ', {fg = '#999999'})"},
    notes = "Set style.ascii for a custom ASCII fallback. Use chain() for automatic color transitions and omitted segments.",
})
add("lush.theme.chain", "Themes", "Join visible prompt components with automatic powerline color transitions.", {
    usage = "lush.theme.chain(components, options?)", output = "chain component descriptor",
    parameters = {"components: list of components or strings; nested chains are not accepted.", "options: optional join settings."},
    flags = {"side: 'left' (default) or 'right'.", "leading/trailing: booleans controlling applicable edge separators.",
             "separator/ascii_separator: optional separator glyph and ASCII fallback."},
    examples = {"lush.theme.chain({lush.theme.path{bg = '#0087D8'}, lush.theme.git{bg = '#d2ff5e'}}, {side = 'left'})"},
    notes = "Unavailable optional segments disappear before joins, avoiding separators around empty components.",
})
add("lush.theme.row", "Themes", "Compose left and right component lists into a prompt header row.", {
    usage = "lush.theme.row{left = {...}, right = {...}}", output = "row descriptor",
    parameters = {"left/right: component or string lists; either may be omitted."},
    examples = {"lush.theme.row{left = {lush.theme.path()}, right = {lush.theme.time()}}"},
    notes = "The native renderer right-aligns the right side using visible Unicode cell widths.",
})
add("lush.theme.prompt", "Themes", "Build a prompt from header rows and input-prefix components.", {
    usage = "lush.theme.prompt{rows = {...}, input = {...}}", output = "prompt descriptor",
    parameters = {"rows: optional list of up to four theme.row descriptors.", "input: components or strings drawn immediately before editable Lua input."},
    examples = {"lush.theme.prompt{rows = {lush.theme.row{left = {lush.theme.path()}}}, input = {lush.theme.text('> ')}}"},
    notes = "Assign the descriptor to lush.config.theme, or return it from a custom theme builder.",
})
add("lush.theme.render", "Themes", "Render a prompt descriptor using an explicit context.", {
    usage = "lush.theme.render(descriptor, context, options?)", output = "{lines = {{left, right}, ...}, input = string}",
    parameters = {"descriptor: a theme.prompt descriptor; call a builder yourself before rendering it.", "context: table with available cwd/home, platform, user/host, time, Git, status, and optional system facts.",
                  "options: optional component switches, otherwise context.options or lush.config.theme_options."},
    examples = {"lush.theme.render(lush.theme.prompt{input = {lush.theme.path(), lush.theme.text(' > ')}}, {cwd = '/work', home = '/home/me', platform = 'linux'})"},
    notes = "Rendering itself reads no system state and launches no processes; context is supplied separately.",
})
add("lush.theme.render_components", "Themes", "Render a component list as styled text using an explicit context.", {
    usage = "lush.theme.render_components(components, context, options?)", output = "string with validated SGR styling",
    parameters = {"components: component or string list.", "context: prompt facts table.", "options: optional component switches."},
    examples = {"lush.theme.render_components({lush.theme.path{fg = '#26C6DA'}}, {cwd = '/work'})"},
})
add("lush.theme.sanitize", "Themes", "Remove terminal escape and control sequences from dynamic prompt text.", {
    usage = "lush.theme.sanitize(value)", output = "plain Unicode string",
    parameters = {"value: text, finite number, boolean, or nil; unsupported values become empty text."},
    examples = {"lush.theme.sanitize('branch\\27[2J')"},
    notes = "Tabs and line breaks become spaces. Invalid UTF-8 is replaced. Component styling is supplied through validated style fields.",
})
add("lush.config", "Configuration", "Configure prompt themes, history, suggestions, and Lua syntax colors.", {
    usage = "lush.config.option = value", output = "configuration table",
    flags = {"theme: name in config.themes or lush.config_dir/themes, prompt descriptor, or builder function; nil or 'plain' uses the default path prompt.",
             "theme_options: boolean switches icons, os, path, git, session, time, status, execution_time, python, battery, root, memory.",
             "themes: optional user-owned table of names mapped to prompt descriptors or builder functions.",
             "prompt: legacy string or callback; takes priority over the selected theme; a callback may return {lines, input}.",
             "history_file: path string, or false to disable disk history.",
             "history_limit: integer from 0 to 100000; default 1000; zero disables history.", "autosuggestions: boolean; default true.",
             "syntax_highlighting: boolean; default true on color-capable terminals."},
    examples = {"lush.config.theme = 'easy-term'", "lush.config.theme_options = {icons = false, git = true}",
                "lush.config.autosuggestions = false", "lush.config.prompt = function() return pwd() .. ' > ' end"},
    notes = "Set options in get_config_dir()/lush/init.lua or an explicit --config file. A prompt override must be removed or set to nil to select a theme. Only the selected theme file is loaded automatically; registry entries take priority. Default history uses get_config_dir()/lush/history.jsonl. Relative history paths are anchored to the startup directory.",
})

-- Help and completion share one producer registry, including method aliases.
for _, command in ipairs(registry) do
    local schema = lush.schemas.producers[command.name] or
                   (command.alias_for and lush.schemas.producers[command.alias_for])
    if schema then
        command.output_schema = schema
        command.output_fields = schema.fields or (schema.items and schema.items.fields)
    end
end
table.sort(registry, function(left, right) return left.name < right.name end)
local function copy(value)
    if type(value) ~= "table" then return value end
    local result = {}
    for key, item in pairs(value) do result[key] = copy(item) end
    return result
end
-- Completion can inspect public metadata without accessing private formatting.
lush.command_registry = copy(registry)
local function string_argument(value, label)
    if type(value) ~= "string" then error(label .. " must be a string", 3) end
    if value:find("\0", 1, true) then error(label .. " cannot contain NUL", 3) end
    return value
end
local function alias_documents()
    local rows, named = {}, {}
    if type(active_aliases) ~= "function" then return rows, named end
    for _, entry in ipairs(active_aliases()) do
        local value = rawget(_G, entry.name)
        if type(value) == "function" then
            local canonical = by_function[value]
            local command = canonical and copy(canonical) or {
                parameters = {"...: arguments forwarded to the alias."}, flags = {}, input = "nothing",
                examples = {entry.name .. "()"},
            }
            command.name, command.category, command.usage = entry.name, "Aliases", entry.name .. "(...)"
            if canonical then
                command.alias_for = canonical.name
                command.description = "Alias for " .. canonical.name .. ": " .. canonical.description
                command.notes = "Alias for " .. canonical.name .. ". " .. canonical.notes
            elseif entry.kind == "external" then
                local arguments = {}
                for index, argument in ipairs(entry.command) do arguments[index] = string.format("%q", argument) end
                command.description = "External command alias for " .. string.format("%q", entry.command[1]) .. "."
                command.output = "Exec (lazy command plan)"
                command.examples = {entry.name .. "()", "run(" .. entry.name .. "())"}
                command.notes = "Command prefix: {" .. table.concat(arguments, ", ") .. "}. " ..
                    "Extra arguments are appended literally. At the prompt, returned command plans execute automatically; scripts use run(" .. entry.name .. "())."
            else
                command.description = "Alias for a Lua function."
                command.output = "values returned by the registered function"
                command.notes = "Calls the registered Lua function with the supplied arguments and returns its values. " ..
                    "A wrapper for an external command must return its command plan; scripts execute that plan with run()."
            end
            rows[#rows + 1], named[entry.name] = command, command
        end
    end
    return rows, named
end
local function current_commands()
    local combined, rows = {}, {}
    for _, command in ipairs(registry) do combined[command.name] = command end
    for _, command in ipairs(alias_documents()) do combined[command.name] = command end
    for _, command in pairs(combined) do rows[#rows + 1] = command end
    table.sort(rows, function(left, right) return left.name < right.name end)
    return rows
end
function lush.commands(query)
    if query ~= nil then query = string_argument(query, "command query"):lower() end
    local rows = {}
    for _, command in ipairs(current_commands()) do
        local searchable = (command.name .. "\n" .. command.description):lower()
        if not query or searchable:find(query, 1, true) then
            rows[#rows + 1] = {name = command.name, category = command.category, description = command.description}
        end
    end
    return stream(rows)
end
commands = lush.commands

local function section(output, heading, values)
    output[#output + 1] = heading .. ":"
    if type(values) == "string" then values = {values} end
    if #values == 0 then output[#output + 1] = "  None." end
    for _, value in ipairs(values) do output[#output + 1] = "  " .. value end
    output[#output + 1] = ""
end
local function output_fields(schema, fields)
    local output, seen = {}, {}
    local function append(path, shape)
        local modifiers = shape.optional and ", optional" or ""
        if shape.data_dependent then modifiers = modifiers .. ", data-dependent" end
        output[#output + 1] = path .. " (" .. shape.type .. modifiers .. "): " ..
            (shape.description or "Each array/stream item.")
        if shape.fields then
            if seen[shape.fields] then
                output[#output] = output[#output] .. " Fields match " .. seen[shape.fields] .. "."
                return
            end
            seen[shape.fields] = path
            for _, nested in ipairs(shape.fields) do append(path .. "." .. nested.name, nested) end
        elseif shape.items then append(path .. "[]", shape.items) end
    end
    if schema.data_dependent then
        output[#output + 1] = schema.description or "Data-dependent: inspect the actual input/output instead of assuming fixed fields."
    end
    if fields then
        seen[fields] = "the output record"
        for _, field in ipairs(fields) do append(field.name, field) end
    elseif schema.items then append("[]", schema.items) end
    return output
end
local function detailed(command)
    local output = {command.name .. " (" .. command.category .. ")", ""}
    section(output, "Description", command.description)
    section(output, "Usage", command.usage)
    section(output, "Flags / options", command.flags)
    section(output, "Parameters", command.parameters)
    section(output, "Input/output", {"input: " .. command.input, "output: " .. command.output})
    if command.output_schema then
        section(output, "Output fields", output_fields(command.output_schema, command.output_fields))
    end
    if command.members then section(output, "Members", command.members) end
    section(output, "Examples", command.examples)
    if command.notes ~= "" then section(output, "Notes", command.notes) end
    return table.concat(output, "\n")
end

-- Inspect the returned value, not its producer or inherited behavior. In
-- particular, pairs/length/tostring/equality on an arbitrary table can run Lua.
local json_array, json_object = getmetatable(json.array()), getmetatable(json.object())
local json_null, flow_meta, exec_meta, result_meta = json.null, lush.Flow, lush.Exec, lush.Result
local key_order = {number = 1, string = 2, boolean = 3, table = 4, ["function"] = 5, thread = 6, userdata = 7}
local keywords = {}
for word in ("and break do else elseif end false for function goto if in local nil not or repeat return then true until while"):gmatch("%S+") do
    keywords[word] = true
end
local function inspect_table(value)
    local max_fields, max_depth, max_key, max_path = 256, 8, 96, 1024
    local cache, seen, output, remaining = {}, {}, {}, max_fields
    local shortened = false
    local function clip(text, limit)
        local last = math.min(#text, limit)
        -- Do not leave the leading bytes of a partially clipped UTF-8 scalar.
        while last > 0 and last < #text do
            local byte = text:byte(last + 1)
            if byte < 128 or byte >= 192 then break end
            last = last - 1
        end
        return text:sub(1, last)
    end
    local function quoted_key(text)
        local escaped = {}
        if utf8.len(text) then
            for _, code in utf8.codes(text) do
                if code == 34 then escaped[#escaped + 1] = '\\"'
                elseif code == 92 then escaped[#escaped + 1] = "\\\\"
                elseif code < 32 or code >= 127 and code <= 159 or code == 0x2028 or code == 0x2029 then
                    escaped[#escaped + 1] = string.format("\\u{%x}", code)
                else escaped[#escaped + 1] = utf8.char(code) end
            end
        else
            -- Lua strings can contain arbitrary bytes, including invalid UTF-8.
            for index = 1, #text do
                local byte = text:byte(index)
                if byte == 34 then escaped[#escaped + 1] = '\\"'
                elseif byte == 92 then escaped[#escaped + 1] = "\\\\"
                elseif byte < 32 or byte >= 127 then escaped[#escaped + 1] = string.format("\\x%02x", byte)
                else escaped[#escaped + 1] = string.char(byte) end
            end
        end
        return table.concat(escaped)
    end
    local function info(item)
        local cached = cache[item]
        if cached then return cached end
        local entry = {keys = {}}
        cache[item] = entry
        if rawequal(item, json_null) then entry.kind = "null"; return entry end
        local key, count, highest, sequence = nil, 0, 0, true
        while true do
            key = next(item, key)
            if key == nil then break end
            if count == max_fields then entry.omitted = true; break end
            count = count + 1
            entry.keys[count] = {key = key, kind = type(key), ordinal = count}
            if math.type(key) ~= "integer" or key < 1 then sequence = false
            elseif key > highest then highest = key end
        end
        table.sort(entry.keys, function(a, b)
            local left, right = key_order[a.kind], key_order[b.kind]
            if left ~= right then return left < right end
            if a.kind == "number" or a.kind == "string" then return a.key < b.key end
            if a.kind == "boolean" then return not a.key and b.key end
            return a.ordinal < b.ordinal
        end)
        local meta = getmetatable(item)
        if rawequal(meta, flow_meta) then entry.kind = "stream"
        elseif rawequal(meta, exec_meta) then entry.kind = "command"
        elseif rawequal(meta, result_meta) then entry.kind = "result"
        elseif rawequal(meta, json_array) then entry.kind = "array"
        elseif rawequal(meta, json_object) then entry.kind = "record"
        elseif count == 0 or entry.omitted and sequence then entry.kind = "table"
        elseif sequence and highest == count then entry.kind = "array"
        else entry.kind = "record" end
        return entry
    end
    local function kind(item)
        if type(item) == "table" then return info(item).kind end
        return math.type(item) or type(item)
    end
    local function key_path(parent, entry)
        local key, label = entry.key
        if entry.kind == "string" then
            if #key <= max_key and key:match("^[A-Za-z_][A-Za-z_0-9]*$") and not keywords[key] then
                label = (parent == "" and "" or ".") .. key
            else
                if #key > max_key then key, shortened = clip(key, max_key), true end
                label = '["' .. quoted_key(key) .. (#entry.key > max_key and "..." or "") .. '"]'
            end
        elseif entry.kind == "number" then
            label = "[" .. string.format(math.type(key) == "integer" and "%d" or "%.17g", key) .. "]"
        elseif entry.kind == "boolean" then label = key and "[true]" or "[false]"
        else label = "[<" .. entry.kind .. " key #" .. entry.ordinal .. ">]" end
        local path = parent .. label
        if #path > max_path then path, shortened = clip(path, max_path) .. "...", true end
        return path
    end
    local function fields(item, parent, depth)
        local entry = info(item)
        for _, key in ipairs(entry.keys) do
            if remaining == 0 then return end
            remaining = remaining - 1
            local path = key_path(parent, key)
            local child = rawget(item, key.key)
            local line = path .. " (" .. kind(child) .. ")"
            local descend = type(child) == "table" and not rawequal(child, json_null)
            if descend then
                if seen[child] then line, descend = line .. ": reference to " .. seen[child], false
                elseif depth == max_depth then
                    if #info(child).keys > 0 or info(child).omitted then line = line .. ": nested fields omitted (depth limit)." end
                    descend = false
                else seen[child] = path end
            end
            output[#output + 1] = line
            if descend then fields(child, path, depth + 1) end
        end
        if entry.omitted then output[#output + 1] = (parent == "" and "Further" or parent .. ": further") .. " fields omitted (table limit)." end
    end
    local root = info(value)
    seen[value] = "<root>"
    fields(value, "", 1)
    if remaining == 0 then output[#output + 1] = "Further fields may be omitted (256-field inspection limit)." end
    local document = {"Table (" .. root.kind .. ")", ""}
    section(document, "Fields", output)
    local notes = {"Types describe the fields present in this value; absent and inherited fields are not included.",
                   "Inspection uses stored fields only. Lazy streams and commands are not evaluated."}
    if root.kind == "stream" then
        notes[#notes + 1] = "For stream items, inspect a collected sample: help(value:first(1):collect()). Use help(producer) for documented output fields."
    end
    if shortened then notes[#notes + 1] = "Long keys or paths were shortened." end
    section(document, "Notes", notes)
    return table.concat(document, "\n")
end
local function overview()
    local groups = {}
    for _, command in ipairs(current_commands()) do
        groups[command.category] = groups[command.category] or {}
        groups[command.category][#groups[command.category] + 1] = command.name
    end
    local categories = {}
    for category in pairs(groups) do categories[#categories + 1] = category end
    table.sort(categories)
    local output = {"Lush: Lua programming with structured shell pipelines.", "", "Discover commands:",
                    "  help('lush')               shell namespace and API members",
                    "  help('ls')                 detailed usage and examples",
                    "  help(version())            actual table fields and types",
                    "  help('commands')           structured command catalog",
                    "  help('find', 'copy')       search names and descriptions", "", "Command categories:"}
    for _, category in ipairs(categories) do
        output[#output + 1] = "  " .. category
        local line = "    "
        for _, name in ipairs(groups[category]) do
            local item = line == "    " and name or ", " .. name
            if #line + #item > 94 then output[#output + 1], line, item = line, "    ", name end
            line = line .. item
        end
        output[#output + 1] = line
    end
    section(output, "Lua examples", {
        "ls():where(function(f) return f.type == 'file' end):select('name', 'size')",
        "show(ls('-la'))", "cmd.git('status')", "run{'git', 'status'}:check()",
        "stream{1, 2, 3}:reduce(function(total, n) return total + n end, 0)",
    })
    output[#output + 1] = "Lua provides variables, functions, loops, and standard libraries."
    output[#output + 1] = "At the prompt, expression results display automatically; scripts use show(value)."
    return table.concat(output, "\n")
end
local function distance(left, right)
    local row = {}
    for index = 0, #right do row[index] = index end
    for i = 1, #left do
        local previous = row[0]
        row[0] = i
        for j = 1, #right do
            local saved = row[j]
            row[j] = math.min(row[j] + 1, row[j - 1] + 1,
                              previous + (left:sub(i, i) == right:sub(j, j) and 0 or 1))
            previous = saved
        end
    end
    return row[#right]
end
function help(topic, query)
    if topic == nil then
        if query ~= nil then error("help topic is required when a query is supplied", 2) end
        return overview()
    end
    if rawequal(topic, lush) then topic = "lush" end
    if type(topic) == "function" then
        if query ~= nil then error("a help query applies only to 'commands' or 'find'", 2) end
        local command = by_function[topic]
        if command then return detailed(command) end
        for _, registered in ipairs(alias_documents()) do
            if rawequal(rawget(_G, registered.name), topic) then return detailed(registered) end
        end
        error("no help is registered for this function. Browse documented functions with help('commands').", 2)
    end
    if type(topic) == "table" then
        if query ~= nil then error("a help query applies only to 'commands' or 'find'", 2) end
        return inspect_table(topic)
    end
    topic = string_argument(topic, "help topic")
    if topic == "commands" then return lush.commands(query) end
    if topic == "find" then
        if query == nil then error("help('find', query) requires search text", 2) end
        return lush.commands(query)
    end
    if query ~= nil then error("a help query applies only to 'commands' or 'find'", 2) end
    if topic == "" then return overview() end
    local _, registered = alias_documents()
    local command = registered[topic] or by_name[topic] or by_name[topic:gsub(":", ".")]
    if not command and topic:sub(1, 5) == "lush." then command = by_name[topic:sub(6)] end
    if command then return detailed(command) end
    local choices = {}
    if #topic <= 128 then
        for _, candidate in ipairs(current_commands()) do
            local score = distance(topic:lower(), candidate.name:lower())
            if score <= math.max(1, math.min(3, math.floor(#topic / 3))) then
                choices[#choices + 1] = {name = candidate.name, score = score}
            end
        end
        table.sort(choices, function(a, b) return a.score == b.score and a.name < b.name or a.score < b.score end)
    end
    local message = "unknown help topic " .. string.format("%q", topic) .. "."
    if #choices > 0 then message = message .. " Did you mean " .. string.format("%q", choices[1].name) .. "?" end
    error(message .. " Search with help('commands', " .. string.format("%q", topic) .. ").", 2)
end
lush.help = help

-- Index the original documented function objects without invoking any value
-- or metatable. Later Lua aliases of these objects retain the same help.
local class_roots = {Flow = lush.Flow, Exec = lush.Exec, Result = lush.Result}
local function binding(name)
    local value, first = _G, true
    for part in name:gmatch("[^.]+") do
        if first then value = class_roots[part] or rawget(_G, part)
        elseif type(value) == "table" then value = rawget(value, part)
        else return nil end
        first = false
    end
    return value
end
local function bind(value, command)
    if type(value) ~= "function" then return end
    local previous = by_function[value]
    if not previous or (previous.alias_for and not command.alias_for) then
        by_function[value] = command
    end
end
for _, command in ipairs(registry) do
    bind(binding(command.name), command)
    -- A Flow method and its global stage factory have distinct identities.
    if not command.name:find(".", 1, true) then
        bind(rawget(lush.Flow, command.name), by_name[command.alias_for] or command)
    end
end
