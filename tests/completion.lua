-- Deterministic lexer, quoting and native-boundary completion regressions.
assert(type(lush.complete) == "function", "completion module is missing")
local native = _lush
local original_list, original_executables, original_platform = native.list, native.executables, native.platform
local original_f = rawget(_G, "f")
local guarded_names, original_guarded = {"stat", "fls_records", "execute"}, {}
for _, name in ipairs(guarded_names) do original_guarded[name] = rawget(native, name) end
local checks, listed = 0, {}
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
    checks = checks + 1
end
local function contains(source, expected, cursor)
    local candidates = lush.complete(source, cursor)
    for index, value in ipairs(candidates) do
        if value == expected then
            assert(type(candidates.labels[index]) == "string")
            checks = checks + 1
            return candidates
        end
    end
    error("missing completion " .. expected .. " for " .. source .. ": " .. table.concat(candidates, ", "))
end
local directories = {
    ["."] = {
        {name = "alpha.txt", type = "file"},
        {name = "apple folder", type = "dir"},
        {name = "alias folder", type = "symlink", is_directory = true},
        {name = 'a"quote.txt', type = "file"},
        {name = "a'quote.txt", type = "file"},
        {name = "a\\back.txt", type = "file"},
        {name = "한글.txt", type = "file"},
        {name = "tools", type = "dir"},
        {name = "private.exe", type = "file", executable = true},
        {name = ".hidden", type = "file"},
    },
    ["tools/"] = {
        {name = "my-tool.exe", type = "file", executable = true},
        {name = "readme.txt", type = "file", executable = false},
        {name = "nested", type = "dir"},
    },
    ["C:\\tools\\"] = {
        {name = "my-tool.exe", type = "file", executable = true},
        {name = "my notes.txt", type = "file"},
    },
    ["C:\\Users\\"] = {{name = "my-tool.exe", type = "file", executable = true}},
}
local names = {"git", "gitk", "my-tool", "end", "tool.Name", 'a"b', "GitUI"}

local ok, problem = xpcall(function()
    native.platform = "unix"
    native.executables = function(prefix)
        assert(type(prefix) == "string")
        return names -- The completion boundary must still filter a snapshot.
    end
    native.list = function(path, all)
        assert(all == true)
        listed[#listed + 1] = path
        return directories[path], "missing directory"
    end

    local found = contains("cmd.gi", "cmd.git")
    equal(#found, 2)
    equal(found.replace_start, 1)
    contains("local job = cmd.gi", "local job = cmd.git")
    contains("cmd.my", 'cmd["my-tool"]')
    contains("cmd.en", 'cmd["end"]')
    contains("cmd.to", 'cmd["tool.Name"]')
    contains('cd("alias', 'cd("alias folder/')
    contains('open("alias', 'open("alias folder/')
    contains('cat("alias', 'cat("alias folder/')
    contains("cmd.a", 'cmd["a\\"b"]')
    contains("lush.cmd.my", 'lush.cmd["my-tool"]')
    for _, value in ipairs(lush.complete("cmd.")) do assert(load("return " .. value)) end
    equal(#lush.complete("cmd.unknown"), 0)
    contains('cmd["my', 'cmd["my-tool')
    contains("cmd['my", "cmd['my-tool")
    contains('cmd("gi', 'cmd("git')
    contains('cmd "gi', 'cmd "git')
    contains('run{"my', 'run{"my-tool')
    contains('capture("my', 'capture("my-tool')
    equal(#lush.complete('cmd("private'), 0) -- No implicit current-directory executable lookup.
    contains('cmd("to', 'cmd("tools/')
    contains('cmd("tools/my', 'cmd("tools/my-tool.exe')
    contains('cmd("tools/ne', 'cmd("tools/nested/')
    equal(#lush.complete('cmd("tools/re'), 0)
    contains('open("tools/re', 'open("tools/readme.txt')
    contains('cat("tools/re', 'cat("tools/readme.txt')
    contains('lush.cat("tools/re', 'lush.cat("tools/readme.txt')
    contains('lush.read("tools/re', 'lush.read("tools/readme.txt')
    contains('cmd.git("al', 'cmd.git("alpha.txt')
    contains('open("ap', 'open("apple folder/')
    contains("open('a\"", "open('a\"quote.txt")
    contains('open("a\\"', 'open("a\\"quote.txt')
    contains("open('a\\'", "open('a\\'quote.txt")
    contains('open("a\\\\', 'open("a\\\\back.txt')
    contains('open("한', 'open("한글.txt')
    contains('cat("한', 'cat("한글.txt')
    contains('open(".', 'open(".hidden')
    contains('print("al', 'print("alpha.txt')
    contains('cd("ap', 'cd("apple folder/')
    contains('cd "ap', 'cd "apple folder/')
    equal(#lush.complete('cd("alpha'), 0)
    equal(#lush.complete('open("missing/'), 0)
    contains('open("\\x61l', 'open("alpha.txt')
    contains('open("\\097l', 'open("alpha.txt')
    contains('open("\\u{61}l', 'open("alpha.txt')
    contains('open("\\z  \n al', 'open("alpha.txt')
    equal(#lush.complete('open("nul\0'), 0)
    equal(#lush.complete('open("bad\nstring'), 0)

    local input = 'open("al")'
    contains(input, 'open("alpha.txt', #'open("al')
    equal(#lush.complete(input, -1), 0)
    equal(#lush.complete(input, #input + 1), 0)
    equal(#lush.complete(input, 1.5), 0)
    equal(#lush.complete(false), 0)
    equal(#lush.complete(""), 0)
    equal(#lush.complete("1."), 0)
    equal(#lush.complete("-- cmd.gi"), 0)
    equal(#lush.complete("--[=[ cmd.gi"), 0)
    equal(#lush.complete("[=[cmd.gi"), 0)
    equal(#lush.complete('print("-- cmd.gi")'), 0)
    contains("-- no execution\ncmd.gi", "-- no execution\ncmd.git")
    contains("--[[ closed ]] cmd.gi", "--[[ closed ]] cmd.git")
    contains("[=[ closed ]=]; cmd.gi", "[=[ closed ]=]; cmd.git")

    completion_visible_global = true
    completion_safe_table = setmetatable({visible = 1, ["hyphen-key"] = 2}, {
        __index = function() error("completion called __index") end,
        __pairs = function() error("completion called __pairs") end,
    })
    contains("completion_vis", "completion_visible_global")
    contains("completion_safe_table.vi", "completion_safe_table.visible")
    contains("completion_safe_table.hy", 'completion_safe_table["hyphen-key"]')
    equal(#lush.complete("completion_safe_table.absent.vi"), 0)
    contains("pri", "print")
    contains("ca", "cat")
    contains("op", "open")
    contains("lush.ca", "lush.cat")
    contains("lush.op", "lush.open")
    contains("ret", "return")
    contains("local answer = pri", "local answer = print")
    completion_visible_global, completion_safe_table = nil, nil

    native.platform = "windows"
    local function open_prefix(path)
        return "open(" .. string.format("%q", path):sub(1, -2)
    end
    for _, base in ipairs({[[\\?\C:\tools\]], [[\\?\UNC\server\share\]]}) do
        directories[base] = {{name = "nested", type = "dir"}}
        directories[base .. [[nested\]]] = {{name = "child.txt", type = "file"}}
        contains(open_prefix(base .. "ne"), open_prefix(base .. [[nested\]]))
        contains(open_prefix(base .. [[nested\chi]]), open_prefix(base .. [[nested\child.txt]]))
    end
    contains("cmd.gi", "cmd.GitUI")
    contains('open("AL', 'open("alpha.txt')
    contains('cat("AL', 'cat("alpha.txt')
    contains('cmd("C:\\\\tools\\\\my', 'cmd("C:\\\\tools\\\\my-tool.exe')
    contains('open("C:\\\\tools\\\\my n', 'open("C:\\\\tools\\\\my notes.txt')
    -- Unknown unfinished escapes can be repaired, while valid Lua escapes
    -- retain their actual meaning (\t is a tab, not a directory separator).
    contains('cmd("C:\\Users\\my', 'cmd("C:\\\\Users\\\\my-tool.exe')
    equal(#lush.complete('cmd("C:\\tools\\my'), 0)

    native.executables = function() error("PATH is temporarily inaccessible") end
    equal(#lush.complete("cmd.gi"), 0)
    native.list = function() error("directory is temporarily inaccessible") end
    equal(#lush.complete('open("a'), 0)
    -- Help completes catalog names, without consulting files or PATH.
    contains('help("path.ba', 'help("path.basename')
    contains("help('sort", "help('sort_by")
    contains('lush.help("path.j', 'lush.help("path.join')
    equal(#lush.complete('help("no-such-command-prefix'), 0)

    -- Callback records come from lexical ls() context and shared metadata,
    -- never from running the listing, callback, or current global `f` value.
    assert(type(lush.schemas) == "table" and type(lush.schemas.file) == "table", "file schema is missing")
    local listing_calls, executable_calls = 0, 0
    native.list = function() listing_calls = listing_calls + 1; error("schema completion listed files") end
    native.executables = function() executable_calls = executable_calls + 1; error("schema completion searched PATH") end
    local evaluation_calls = 0
    for _, name in ipairs(guarded_names) do
        native[name] = function() evaluation_calls = evaluation_calls + 1; error("schema completion executed " .. name) end
    end
    f = setmetatable({global_only = true}, {
        __index = function() error("schema completion indexed the global record") end,
        __pairs = function() error("schema completion inspected a user metatable") end,
    })
    local function file_completion(source, parameter)
        local expected = source .. "size"
        local result = contains(source, expected)
        for index, replacement in ipairs(result) do
            if replacement == expected then
                assert(result.labels[index]:find("size : integer", 1, true), result.labels[index])
                assert(result.labels[index]:find("byte", 1, true), result.labels[index])
            end
            assert(not replacement:find("global_only", 1, true), "global value overrode a callback parameter")
        end
        return result
    end
    local primary = "ls():where(function(f) return f."
    local all_fields = file_completion(primary)
    equal(#all_fields, #lush.schemas.file)
    contains(primary .. "si", primary .. "size")
    equal(#lush.complete(primary .. "Size"), 0)
    local optional = contains(primary .. "mod", primary .. "modified")
    assert(optional.labels[1]:find("integer?", 1, true), optional.labels[1])
    for _, method in ipairs{"where", "filter", "map", "each", "foreach", "any", "all", "sort_by"} do
        file_completion("ls():" .. method .. "(function(entry) return entry.")
        file_completion("lush.ls('-la', '.'):" .. method .. "(function(file, index) return file.")
    end
    file_completion("ls():where(function(f) return f.size > 1 end):take(3):where(function(record) return record.")
    file_completion("ls():sort_by('size'):reverse():first(2):uniq('name'):where(function(f) return f.")
    file_completion("ls():where(function(f) local function inner(other) return f.")
    file_completion("ls():where(function(f) local function inner(f) return 1 end; return f.")
    file_completion("ls():where(function(f) do local f={} end; return f.")
    file_completion("ls():where(function(f) if true then local f={} else return f.")
    file_completion("ls() | where(function(f) return f.")
    file_completion("lush.ls() | where(function(entry) return entry.")
    file_completion("ls() | where(function(f) return true end) | take(2) | map(function(entry) return entry.")
    local continued = lush.complete("return entry.si", nil, "ls():where(function(entry)")
    equal(continued[1], "return entry.size")
    local pending_quoted = lush.complete('return entry["si', nil, "ls():map(function(entry)")
    equal(pending_quoted[1], 'return entry["size')
    equal(#lush.complete("return f.si", nil, "ls():where(function(f)\nlocal f={}"), 0)
    equal(#lush.complete("f.si", nil, "ls():where(function(f)\n--[=["), 0)
    equal(#lush.complete("f.si", nil, "ls():where(function(f)\nlocal text=[=["), 0)
    contains('ls():where(function(f) return f["si', 'ls():where(function(f) return f["size')
    contains("ls():where(function(f) return f['si", "ls():where(function(f) return f['size")

    for _, source in ipairs{
        "ls():where(function(f) local f={}; return f.si",
        "ls():where(function(f) f={}; return f.si",
        "ls():where(function(f) do local f={}; return f.si",
        "ls():where(function(f) local function inner(f) return f.si",
        "ls():where(function(_, f) return f.si",
        "ls():where(function(file, f) return f.si",
        "unknown(function(f) return f.si",
        "ls():map(function(f) return {} end):where(function(f) return f.si",
        "ls():each(function(f) return f end):where(function(f) return f.si",
        "ls() | map(function(f) return {} end) | where(function(f) return f.si",
        "ls():get('name'):where(function(f) return f.si",
        "local ls=function() return {} end; ls():where(function(f) return f.si",
        "local lush={}; lush.ls():where(function(f) return f.si",
        "ls():where(function(f) return f.size.si",
    } do equal(#lush.complete(source), 0) end
    contains("ls():where(function(f) return f.size end); f.glo", "ls():where(function(f) return f.size end); f.global_only")
    contains("local function other(f) return f end; f.glo", "local function other(f) return f end; f.global_only")
    -- All fixed producer hints use the shared descriptor graph, including
    -- direct expressions, lexical locals, stream items, and nested arrays.
    for _, pair in ipairs{
        {"stat('missing-do-not-touch').si", "stat('missing-do-not-touch').size"},
        {"lush.stat('missing').mod", "lush.stat('missing').modified"},
        {"version().pl", "version().platform"},
        {"local info=version(); info.pl", "local info=version(); info.platform"},
        {"local info=stat('missing'); info.si", "local info=stat('missing'); info.size"},
        {"local info <const> = stat('missing'); info.pa", "local info <const> = stat('missing'); info.path"},
        {"local info=version(); local copy=info; copy.pl", "local info=version(); local copy=info; copy.platform"},
        {"commands():where(function(c) return c.na", "commands():where(function(c) return c.name"},
        {"lush.commands():map(function(c) return c.ca", "lush.commands():map(function(c) return c.category"},
        {"help('commands'):where(function(c) return c.de", "help('commands'):where(function(c) return c.description"},
        {"help('find', 'ls'):foreach(function(c) return c.na", "help('find', 'ls'):foreach(function(c) return c.name"},
        {"local result=capture(cmd.nonexistent()); result.std", "local result=capture(cmd.nonexistent()); result.stdout"},
        {"local result=run(cmd.nonexistent()); result.co", "local result=run(cmd.nonexistent()); result.code"},
        {"cmd.git():capture().std", "cmd.git():capture().stdout"},
        {"cmd['not-real']():run():check().sta", "cmd['not-real']():run():check().statuses"},
        {"local task=lush.cmd.git(); task.com", "local task=lush.cmd.git(); task.commands"},
        {"ls():enumerate():where(function(row) return row.in", "ls():enumerate():where(function(row) return row.index"},
        {"ls():enumerate():where(function(row) return row.item.si", "ls():enumerate():where(function(row) return row.item.size"},
        {"commands():enumerate():map(function(row) return row.item.na", "commands():enumerate():map(function(row) return row.item.name"},
        {"local rows=ls(); rows:enumerate():each(function(row) return row.item.si", "local rows=ls(); rows:enumerate():each(function(row) return row.item.size"},
        {"stream{stat('missing')}:where(function(s) return s.si", "stream{stat('missing')}:where(function(s) return s.size"},
        {"lush.stream({version()}):map(function(s) return s.pl", "lush.stream({version()}):map(function(s) return s.platform"},
        {"lush.theme.path().st", "lush.theme.path().style"},
        {"local spec=lush.theme.prompt{}; spec.ro", "local spec=lush.theme.prompt{}; spec.rows"},
        {"lush.theme.render(lush.theme.prompt{},{}).lines[1].le", "lush.theme.render(lush.theme.prompt{},{}).lines[1].left"},
        {"ls():collect()[1].si", "ls():collect()[1].size"},
        {"ls():where(function(f) local f=f; return f.si", "ls():where(function(f) local f=f; return f.size"},
        {"local stat=stat('missing').si", "local stat=stat('missing').size"},
        {"local info=version(); local data={info=stat('missing')}; info.pl", "local info=version(); local data={info=stat('missing')}; info.platform"},
        {"ls():where(function(f) local f=f or f.si", "ls():where(function(f) local f=f or f.size"},
        {"ls():where(function(f) local f=(function() return f.si", "ls():where(function(f) local f=(function() return f.size"},
    } do contains(pair[1], pair[2]) end
    local pending_record = lush.complete("info.pl", nil, "local info=version()")
    equal(pending_record[1], "info.platform")
    local pending_stream = lush.complete("return row.item.si", nil, "local entries=ls()\nentries:enumerate():where(function(row)")
    equal(pending_stream[1], "return row.item.size")
    local result_fields = lush.complete("local result=capture(cmd.nonexistent()); result.st")
    equal(#result_fields, 3)
    for _, source in ipairs{
        "local info=version(); info=unknown(); info.pl",
        "local info=version(); info=unknown() or {}; info.pl",
        "local info=version(); info = unknown() + 1\ninfo.pl",
        "local info=version(); if test then info=stat('missing') end; info.si",
        "local info=version(); local function later() info=stat('missing') end; info.si",
        "local info=version(); do local info={} ; info.pl",
        "local stat=function() end; stat('missing').si",
        "local commands=function() end; commands():where(function(c) return c.na",
        "unknown(stat('missing')).si",
        "from_json('{\"size\":1}'):where(function(x) return x.si",
        "json.decode('{\"size\":1}').si",
        "commands():map(function(c) return {} end):where(function(c) return c.na",
        "ls():enumerate():map(function(row) return {} end):where(function(row) return row.item.si",
        "local info=version(); local function inner(info) return info.pl",
        "ls():where(function(f) local f=function() return f end; return f.si",
    } do equal(#lush.complete(source), 0) end
    equal(lush.schemas.enumerated[2].type, "any") -- inference must not mutate shared schemas
    equal(listing_calls, 0)
    equal(executable_calls, 0)
    equal(evaluation_calls, 0)
    equal(#lush.complete("ls():where(function(f) -- f.si"), 0)
    equal(#lush.complete("ls():where(function(f) --[=[ f.si"), 0)
    equal(#lush.complete("ls():where(function(f) return [=[f.si"), 0)
    equal(#lush.complete('ls():where(function(f) return "f.si'), 0)
    local with_suffix = 'ls():where(function(entry) return entry.si == 2 end)'
    local caret = assert(with_suffix:find("si ==", 1, true)) + 1
    contains(with_suffix, 'ls():where(function(entry) return entry.size', caret)
    local examples = {
        'ls():where(function(file) local s="한글"; return file.size > 1 end)',
        'ls():map(function(f) return {name=f.name} end):where(function(f) return f.name end)',
        'ls():where(function(f) if true then local f={} end; return f.size end)',
        'local info=version(); info.platform',
        'local result=capture(cmd["한글"]()); result.statuses[1]',
        'commands():enumerate():where(function(row) return row.item.name end)',
        'local stat=stat("missing"); stat.size',
    }
    for _, example in ipairs(examples) do
        for length = 0, #example do
            local result = lush.complete(example:sub(1, length))
            assert(type(result) == "table")
            for _, replacement in ipairs(result) do assert(type(replacement) == "string") end
        end
    end
end, debug.traceback)

native.list, native.executables, native.platform = original_list, original_executables, original_platform
for _, name in ipairs(guarded_names) do native[name] = original_guarded[name] end
completion_visible_global, completion_safe_table = nil, nil
f = original_f
assert(ok, problem)
print("completion: " .. checks .. " checks passed")
