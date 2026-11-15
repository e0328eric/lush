-- Command discovery and help are data; examples are compiled, never executed.
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function contains(text, needle)
    check(type(text) == "string" and text:find(needle, 1, true), tostring(needle) .. " missing from help")
end
local function rejects(callback, needle)
    local ok, message = pcall(callback)
    check(not ok and tostring(message):find(needle, 1, true), tostring(message))
    return tostring(message)
end
check(help == lush.help, "global help and lush.help differ")
check(commands == lush.commands, "global catalog differs from lush.commands")
local overview = help()
for _, word in ipairs({"Lua", "Filesystem", "Data", "Formats", "Processes", "help('ls')", "help('commands')"}) do
    contains(overview, word)
end
check(help("") == overview and help(nil) == overview, "empty help did not show the overview")

local ls_help = help("ls")
for _, heading in ipairs({"Description:", "Usage:", "Flags / options:", "Parameters:", "Input/output:", "Examples:"}) do
    contains(ls_help, heading)
end
for _, flag in ipairs({"--all", "--long", "--tree", "--tui", "--lol=signal", "--snapshot"}) do
    contains(ls_help, flag)
end
contains(ls_help, "Output fields:")
contains(ls_help, "f is one file record")
contains(ls_help, "Return true to keep it or false to skip it")
contains(ls_help, "print() returns nil")
contains(ls_help, "foreach(function(f) print(f.size) end)")
contains(ls_help, "ls():columns()")
contains(ls_help, "ls():first(1)")
contains(ls_help, "ls():get('size')")
check(ls_help:find("Output fields:", 1, true) < ls_help:find("Examples:", 1, true),
      "record fields should be visible before examples")
local file_schema, field_names = lush.schemas.file, {}
check(type(file_schema) == "table" and #file_schema == 11, "file field metadata is missing")
for _, field in ipairs(file_schema) do
    check(type(field.name) == "string" and type(field.type) == "string" and
          type(field.description) == "string" and #field.description > 0 and
          type(field.optional) == "boolean", "invalid file field metadata")
    check(not field_names[field.name], "duplicate file field metadata")
    field_names[field.name] = field
    contains(ls_help, field.name .. " (" .. field.type .. (field.optional and ", optional" or "") .. "):")
end
for _, name in ipairs({"name", "path", "type", "kind", "size", "depth"}) do
    check(field_names[name] and not field_names[name].optional, "required file field is undocumented: " .. name)
end
for _, name in ipairs({"modified", "git", "git_x", "git_y", "link_target"}) do
    check(field_names[name] and field_names[name].optional, "optional file field is undocumented: " .. name)
end
for _, record in ipairs(ls():first(3):collect()) do
    for _, field in ipairs(file_schema) do
        local value = record[field.name]
        check(value ~= nil or field.optional, "required native file field is absent: " .. field.name)
        if value ~= nil then
            check(field.type == "integer" and math.type(value) == "integer" or type(value) == field.type,
                  "native file field type differs from metadata: " .. field.name)
        end
    end
    for name in pairs(record) do check(field_names[name], "undocumented native file field: " .. name) end
    check(record.kind == record.type, "file kind alias changed")
end

-- One canonical descriptor format covers records, arrays, nested fields and
-- streams. Shared subtrees are allowed; cycles would break help snapshots.
local function metadata_shape(shape, active)
    active = active or {}
    check(type(shape) == "table" and type(shape.type) == "string", "invalid output descriptor")
    check(not active[shape], "output metadata contains a cycle")
    active[shape] = true
    if shape.fields then
        check(not active[shape.fields], "field metadata contains a cycle")
        active[shape.fields] = true
        local names = {}
        for _, field in ipairs(shape.fields) do
            check(type(field.name) == "string" and not names[field.name] and
                  type(field.description) == "string" and type(field.optional) == "boolean",
                  "invalid nested field metadata")
            names[field.name] = true
            metadata_shape(field, active)
        end
        active[shape.fields] = nil
    end
    if shape.items then metadata_shape(shape.items, active) end
    active[shape] = nil
end
for name, shape in pairs(lush.schemas.producers) do
    check(type(name) == "string", "producer metadata has an invalid name")
    metadata_shape(shape)
end
local function actual_shape(value, shape, label)
    local matched = false
    for kind in shape.type:gmatch("[^|]+") do
        matched = matched or kind == "any" or
                  kind == "integer" and math.type(value) == "integer" or
                  (kind == "record" or kind == "array") and type(value) == "table" or
                  kind == "stream" and getmetatable(value) == lush.Flow or type(value) == kind
    end
    check(matched, label .. " differs from documented type " .. shape.type)
    if shape.fields then
        local known = {}
        for _, field in ipairs(shape.fields) do
            known[field.name] = true
            local item = value[field.name]
            check(item ~= nil or field.optional, label .. " lacks " .. field.name)
            if item ~= nil then actual_shape(item, field, label .. "." .. field.name) end
        end
        if not shape.data_dependent then
            for name in pairs(value) do check(known[name], label .. " has undocumented field " .. tostring(name)) end
        end
    elseif shape.items then
        local items = shape.type == "stream" and value:collect() or value
        for index, item in ipairs(items) do actual_shape(item, shape.items, label .. "[" .. index .. "]") end
    end
end
actual_shape(stat("README.md"), lush.schemas.producers.stat, "stat")
actual_shape(version(), lush.schemas.producers.version, "version")
actual_shape(commands("copy"), lush.schemas.producers.commands, "commands")
actual_shape(help("commands", "copy"), lush.schemas.producers["help.commands"], "help commands")
actual_shape(stream{{name = "one"}, 2}:enumerate(), lush.schemas.producers.enumerate, "enumerate")
actual_shape(cmd("not-executed", "literal argument"), lush.schemas.producers.cmd, "command plan")
actual_shape("input bytes" | cmd("not-executed"), lush.schemas.producers.cmd, "command with input")
local executable = which("git")
if executable then
    local result = capture{executable, "--version"}
    actual_shape(result, lush.schemas.producers.capture, "capture")
    actual_shape(result:check(), lush.schemas.producers["Result.check"], "Result.check")
end
local t = lush.theme
for _, name in ipairs{"os", "path", "git", "session", "time", "status", "execution_time", "python", "battery", "root", "memory"} do
    actual_shape(t[name]{fg = "#abc", custom_option = "user-owned"},
                 lush.schemas.producers["lush.theme." .. name], "theme " .. name)
end
local text_component = t.text(42, {bold = true})
actual_shape(text_component, lush.schemas.producers["lush.theme.text"], "theme text")
actual_shape(t.separator(" | "), lush.schemas.producers["lush.theme.separator"], "theme separator")
local chain = t.chain({text_component, t.path()})
actual_shape(chain, lush.schemas.producers["lush.theme.chain"], "theme chain")
local row = t.row{left = {chain}, right = {t.time()}}
actual_shape(row, lush.schemas.producers["lush.theme.row"], "theme row")
local prompt = t.prompt{rows = {row}, input = {t.status()}}
actual_shape(prompt, lush.schemas.producers["lush.theme.prompt"], "theme prompt")
actual_shape(t.render(prompt, {cwd = "/work", last_status = 0}),
             lush.schemas.producers["lush.theme.render"], "rendered prompt")
for _, topic in ipairs{"stat", "version", "run", "capture", "Exec.run", "Exec.capture", "Result.check",
                       "enumerate", "cmd", "lush.theme.text", "lush.theme.chain", "lush.theme.row", "lush.theme.prompt", "lush.theme.render"} do
    contains(help(topic), "Output fields:")
end
contains(help(commands), "category (string)")
contains(help("capture"), "statuses[] (integer)")
contains(help("cmd"), "commands[][] (string)")
contains(help("enumerate"), "item (any, data-dependent)")
contains(help("lush.theme.prompt"), "rows[].kind (string)")
contains(help("lush.theme.render"), "lines[].left (string)")
contains(help("lush.theme.render"), "lines[].right (string)")
for _, topic in ipairs{"source", "stream", "pipe", "collect", "map", "select", "get", "json.decode", "from.json"} do
    local text = help(topic)
    contains(text, "Data-dependent")
    check(not text:find("name (string):", 1, true), "data-dependent output invented file fields: " .. topic)
end
contains(help("cp"), "recursive")
contains(help("cp"), "overwrite")
contains(help("cp"), "exact")
contains(help("source"), "...")
contains(help("path.expand"), "%NAME%")
contains(help("path.expand"), "${NAME}")
contains(help("clear"), "interactive")
contains(help("reduce"), "initial")
contains(help("reduce"), "explicit nil")
contains(help("uniq"), "structurally")
contains(help("contains"), "identity")
contains(help("all"), "empty input is true")
contains(help("first"), "as a stream")
contains(help("exists"), "dangling")
contains(help("cat"), "byte string")
contains(help("cat"), "raw bytes")
contains(help("cat"), "from.json(cat('settings.json'))")
contains(help("open"), "Windows default application")
contains(help("open"), "open(target)")
contains(help("open"), "without waiting")
contains(help("open"), "NUL")
contains(help("lush.read"), "Alias for cat.")
check(open ~= cat, "application opener and byte reader share a function")
check(lush.open == open and lush.cat == cat and lush.read == cat, "open/cat namespace aliases differ")
contains(help("lush.config"), "get_config_dir()")
contains(help("lush.config"), "syntax_highlighting")
contains(help("lush.config"), "theme_options")
contains(help("lush.config"), "takes priority")
contains(help("lush.theme"), "Members:")
contains(help("lush.config.themes"), "user-owned")
contains(help("lush.config.themes"), "source(")
contains(help("lush.config.themes"), ".lua")
contains(help("lush.theme.render"), "context")
contains(help("lush.theme.chain"), "powerline")
contains(help("lush.run"), "run(")
contains(help("Result:check"), "result:check()")

-- Function values resolve by identity without running the supplied function.
check(help(ls) == help("ls") and help(lush.ls) == help("ls"), "function help differs from named help")
check(help(open) == help("open") and help(lush.open) == help("open"), "opener lacks function help")
check(help("lush.open") == help("open"), "qualified opener help differs")
check(help(cat) == help("cat") and help(lush.cat) == help("cat") and help(lush.read) == help("cat"),
      "byte-reader aliases lack canonical function help")
check(help("lush.cat") == help("cat"), "qualified byte-reader help differs")
local list_files = ls
check(help(list_files) == help("ls"), "a local function alias lost its documentation")
check(help(path.join) == help("path.join"), "namespace function help failed")
check(help(map) == help("each") and help(filter) == help("where"), "shared aliases lack canonical help")
check(help(lush.Flow.map) == help("each"), "Flow methods lack function help")
check(help(lush.Result.check) == help("Result.check"), "class method lookup failed")
check(help(commands) == help("lush.commands"), "function help returned the command catalog")
check(help(help) == help("help"), "help function was not indexed after initialization")
for _, name in ipairs({"text", "os", "path", "git", "session", "time", "status", "execution_time",
                       "python", "battery", "root", "memory", "separator", "chain", "row", "prompt",
                       "render", "render_components", "sanitize"}) do
    check(help(lush.theme[name]) == help("lush.theme." .. name), "theme component lacks function help: " .. name)
end
local called = false
local function undocumented() called = true end
rejects(function() help(undocumented) end, "no help is registered for this function")
check(not called, "help invoked an undocumented function")
rejects(function() help(ls, "extra") end, "query applies only")

local catalog = commands()
check(getmetatable(catalog) == lush.Flow, "catalog is not a structured Flow")
check(describe(catalog) == "stream", "catalog type changed")
local rows, names = catalog:collect(), {}
check(#rows >= 80, "command registry omitted existing command groups")
for index, row in ipairs(rows) do
    check(type(row.name) == "string" and type(row.category) == "string" and
          type(row.description) == "string", "catalog row has an invalid schema")
    check(not names[row.name], "duplicate command name: " .. row.name)
    names[row.name] = true
    if index > 1 then check(rows[index - 1].name < row.name, "catalog is not sorted") end
end
check(names["lush.config.themes"] and not names["lush.themes"], "theme discovery does not describe the user-owned registry")
for _, name in ipairs({"help", "commands", "ls", "sl", "pwd", "cd", "open", "cat", "save", "mkdir", "touch",
                       "cp", "mv", "rm", "stat", "exists", "path", "path.join", "path.expand", "path.exists",
                       "stream", "where", "filter", "each", "map", "select", "get", "take", "skip", "sort_by",
                       "reverse", "uniq", "first", "last", "enumerate", "flatten", "append", "prepend", "columns",
                       "reject", "rename", "update", "default", "any", "all", "reduce", "collect", "count",
                       "from.lines", "lines", "from.json", "to.json", "to.text", "json.encode", "json.decode", "json.null",
                       "cmd", "run", "capture", "pipe", "lush.stage", "which", "source", "describe", "version", "clear",
                       "echo", "printf", "contains", "show", "exit", "env", "lush.config"}) do
    check(names[name], "missing command metadata: " .. name)
end
local previous = rows[1].name
rows[1].name, rows[1].description = "mutated row", "mutated description"
check(commands():collect()[1].name == previous, "catalog result mutated later discovery")
check(#commands(""):collect() == #rows, "empty search omitted commands")
check(#help("commands"):collect() == #rows, "help commands differs from the catalog")

for _, query in ipairs({"JSON", "CoPy", "table", "absent-lush-command-483629", "["}) do
    local filtered = commands(query):collect()
    for _, row in ipairs(filtered) do
        check((row.name .. "\n" .. row.description):lower():find(query:lower(), 1, true),
              "search matched outside names/descriptions or interpreted a Lua pattern")
    end
    check(json.encode(filtered) == json.encode(help("commands", query):collect()), "help catalog filtering differs")
    check(json.encode(filtered) == json.encode(help("find", query):collect()), "find alias filtering differs")
end
check(#commands("JSON"):collect() > 0, "case-insensitive JSON search found no commands")
check(#commands("absent-lush-command-483629"):collect() == 0, "unknown search was not empty")
local projected = commands("copy"):select("name"):collect()
check(#projected > 0 and type(projected[1].name) == "string", "catalog did not compose with record transforms")

local message = rejects(function() help("lss") end, "unknown help topic")
contains(message, '"ls"')
contains(message, "Did you mean")
contains(message, "help('commands'")
rejects(function() help(false) end, "help topic must be a string")
rejects(function() help("find") end, "requires search text")
rejects(function() help("commands", {}) end, "command query must be a string")
rejects(function() commands(false) end, "command query must be a string")
rejects(function() help(nil, "ls") end, "topic is required")
rejects(function() help("ls", "extra") end, "query applies only")
rejects(function() help("bad\0topic") end, "NUL")
rejects(function() commands("bad\0query") end, "NUL")

local namespaces = {Flow = lush.Flow, Exec = lush.Exec, Result = lush.Result}
local function resolve(name)
    local value, first = _G, true
    for part in name:gmatch("[^.]+") do
        value = first and (namespaces[part] or rawget(_G, part)) or
                type(value) == "table" and rawget(value, part) or nil
        first = false
    end
    return value
end
check(type(lush.command_registry) == "table" and #lush.command_registry == #rows,
      "completion metadata does not match command discovery")
for _, command in ipairs(lush.command_registry) do
    -- User-defined configuration entries are documented even before init.lua creates them.
    if command.name ~= "lush.config.themes" then
        check(resolve(command.name) ~= nil, "documented command is unavailable: " .. command.name)
    end
    check(type(command.usage) == "string" and type(command.parameters) == "table" and
          type(command.flags) == "table" and type(command.input) == "string" and
          type(command.output) == "string" and type(command.examples) == "table",
          "incomplete help schema for " .. command.name)
    local expected = lush.schemas.producers[command.name] or
                     (command.alias_for and lush.schemas.producers[command.alias_for])
    if expected then
        check(json.encode(command.output_schema) == json.encode(expected),
              "help output differs from canonical producer metadata: " .. command.name)
        local fields = expected.fields or (expected.items and expected.items.fields)
        check(json.encode(command.output_fields) == json.encode(fields),
              "help fields differ from canonical producer metadata: " .. command.name)
    end
    -- 'commands' is the structured catalog topic; its qualified Lua name
    -- selects detailed documentation for the catalog function itself.
    local text = help(command.name == "commands" and "lush.commands" or command.name)
    for _, heading in ipairs({"Description:", "Usage:", "Flags / options:", "Parameters:", "Input/output:", "Examples:"}) do
        contains(text, heading)
    end
    for _, example in ipairs(command.examples) do
        local chunk, problem = load("return " .. example, "=help example", "t", {})
        if not chunk then chunk, problem = load(example, "=help example", "t", {}) end
        check(chunk ~= nil, command.name .. " contains an invalid Lua example: " .. tostring(problem))
    end
end
print("Help checks passed: " .. checks)
