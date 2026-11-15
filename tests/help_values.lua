-- Inspect returned tables without executing their contents or metamethods.
-- Run: build/lush.exe --no-config tests/help_values.lua
local checks = 0
local function check(value, message)
    assert(value, message)
    checks = checks + 1
end
local function contains(text, needle)
    check(type(text) == "string" and text:find(needle, 1, true), "missing inspection text: " .. needle)
end
local function field(text, path, kind)
    for line in text:gmatch("[^\n]+") do
        if line:find(path, 1, true) and line:find("(" .. kind .. ")", 1, true) then
            check(true, "field type found")
            return
        end
    end
    check(false, "missing field/type: " .. path .. " / " .. kind .. "\n" .. text)
end
local function report(value)
    local text = help(value)
    check(type(text) == "string" and #text > 0, "table help did not return text")
    contains(text, "Fields:")
    return text
end

-- The requested examples inspect the values, rather than the producer's topic.
local version_text = report(version())
for _, name in ipairs{"name", "version", "lua", "platform"} do field(version_text, name, "string") end
local stat_value = stat(".")
local stat_text = report(stat_value)
for _, name in ipairs{"name", "path", "type"} do field(stat_text, name, "string") end
field(stat_text, "size", "integer")
if stat_value.modified ~= nil then field(stat_text, "modified", "integer") end

local calls = 0
local function produced()
    calls = calls + 1
    return {enabled = false, count = 7, ratio = 1.25, text = "payload", missing = nil,
            config = {name = "nested"}, items = {{name = "first"}, {name = "second"}}}
end
local nested = report(produced())
check(calls == 1, "inspection invoked a producer again")
field(nested, "enabled", "boolean")
field(nested, "count", "integer")
field(nested, "ratio", "float")
field(nested, "text", "string")
field(nested, "config.name", "string")
field(nested, "items[1].name", "string")
field(nested, "items[2].name", "string")
check(not nested:find("missing (", 1, true), "absent nil field was invented")
check(not nested:find("payload", 1, true), "inspection unexpectedly serialized values")

local sequence = report({"one", false, 3, 2.5})
field(sequence, "[1]", "string")
field(sequence, "[2]", "boolean")
field(sequence, "[3]", "integer")
field(sequence, "[4]", "float")
local sparse = report(json.array{[1] = "first", [3] = true})
field(sparse, "[1]", "string")
field(sparse, "[3]", "boolean")
check(not sparse:find("[2]", 1, true), "a missing sparse-array entry was invented")

report({})
contains(report(json.array()), "array")
contains(report(json.object()), "record")
contains(report(json.null), "null")
field(report({nothing = json.null}), "nothing", "null")

local shared = {number = 17}
local graph = {first = shared, second = shared}
graph.self = graph
local cyclic = report(graph)
contains(cyclic, "self")
contains(cyclic:lower(), "reference")
check(cyclic:find("first.number", 1, true) or cyclic:find("second.number", 1, true),
      "shared record fields were never inspected")
check(#cyclic < 10000, "cycle/shared-reference output is unbounded")

-- Every metamethod would fail if touched, even if the inspector suppressed it.
local traps = {}
local metatable = {}
for _, name in ipairs{"__index", "__pairs", "__len", "__tostring", "__eq", "__lt", "__le", "__call"} do
    metatable[name] = function()
        traps[name] = (traps[name] or 0) + 1
        error("inspection invoked " .. name)
    end
end
local object = setmetatable({stored = 1}, metatable)
local key_one, key_two = setmetatable({}, metatable), setmetatable({}, metatable)
local function callback() calls = calls + 1; error("callback was invoked") end
local thread = coroutine.create(callback)
object.callback, object.thread, object.handle = callback, thread, io.stdout
object[key_one], object[key_two] = "first table key", "second table key"
object[callback], object[thread] = true, 9
object[true], object[3], object["3"], object[1.25] = false, "numeric key", 7, 2.5
object["odd.key"], object["end"] = 3, "keyword key"
object["escape\27[2J"] = 1
local trap_report = report(object)
field(trap_report, "stored", "integer")
field(trap_report, "callback", "function")
field(trap_report, "thread", "thread")
field(trap_report, "handle", "userdata")
field(trap_report, "[true]", "boolean")
field(trap_report, "[3]", "string")
field(trap_report, '["3"]', "integer")
field(trap_report, "[1.25]", "float")
field(trap_report, "odd.key", "integer")
field(trap_report, '["end"]', "string")
check(not trap_report:find("\27", 1, true), "string key emitted a terminal control sequence")
for name, count in pairs(traps) do check(count == 0, "metamethod was invoked: " .. name) end
check(next(traps) == nil, "a trapped metamethod was invoked")
check(calls == 1 and coroutine.status(thread) == "suspended", "a stored callback/thread was executed")
local protected = setmetatable({visible = true}, {__metatable = "protected", __index = metatable.__index})
field(report(protected), "visible", "boolean")
check(next(traps) == nil, "protected metatable triggered inspection behavior")

local executions = 0
local lazy = setmetatable({resolve = function() executions = executions + 1; error("lazy evaluation") end}, lush.Flow)
local lazy_text = report(lazy)
field(lazy_text, "resolve", "function")
contains(lazy_text:lower(), "not evaluated")
check(executions == 0, "table help resolved a lazy stream")
local plan = cmd("not-executed", "literal argument")
local original_execute = _lush.execute
_lush.execute = function() executions = executions + 1; error("process evaluation") end
local ok, plan_text = pcall(help, plan)
_lush.execute = original_execute
check(ok and type(plan_text) == "string", "command-plan help failed")
field(plan_text, "commands[1][1]", "string")
field(plan_text, "commands[1][2]", "string")
check(executions == 0, "table help executed a command plan")

local many = {}
for index = 1, 20000 do many[string.format("field%05d", index)] = index end
local bounded = report(many)
contains(bounded:lower(), "omitted")
check(#bounded < 100000, "large table produced excessive output")
local displayed = 0
for line in bounded:gmatch("[^\n]+") do
    if line:find(" (integer)", 1, true) then displayed = displayed + 1 end
end
check(displayed > 0 and displayed <= 256, "field budget was not enforced")
local broad = {}
for group = 1, 30 do
    local child = {}
    for index = 1, 30 do child[string.format("value%02d", index)] = index end
    broad[string.format("group%02d", group)] = child
end
local broad_report = report(broad)
contains(broad_report:lower(), "omitted")
local total_fields = 0
for line in broad_report:gmatch("[^\n]+") do
    if line:match("^  .+ %([a-z]+%)") then total_fields = total_fields + 1 end
end
check(total_fields > 100 and total_fields <= 256, "nested tables did not share the global field budget")
local deep, current = {}, nil
current = deep
for index = 1, 2000 do current.child = {}; current = current.child end
current.final_value = true
local depth_report = report(deep)
contains(depth_report:lower(), "omitted")
check(#depth_report < 10000 and not depth_report:find("final_value", 1, true), "depth budget was not enforced")
local long_report = report({["k" .. ("한"):rep(5000)] = 1})
check(#long_report < 5000, "long key was not bounded")
check(utf8.len(long_report) ~= nil, "key shortening split a UTF-8 scalar")
local deep_names, node = {}, nil
node = deep_names
for index = 1, 9 do local child = {}; node[("界"):rep(32)] = child; node = child end
local path_report = report(deep_names)
check(#path_report < 30000 and utf8.len(path_report) ~= nil, "nested Unicode paths are not bounded valid UTF-8")
local controls = "control" .. string.char(0, 27, 127, 255, 128) .. "\u{85}\u{2028}\u{2029}"
local control_report = report({[controls] = 1})
check(utf8.len(control_report) ~= nil, "invalid-byte key produced invalid UTF-8 output")
for _, control in ipairs{string.char(0), string.char(27), string.char(127), "\u{85}", "\u{2028}", "\u{2029}"} do
    check(not control_report:find(control, 1, true), "key emitted a raw control or line separator")
end
local huge_value = report({payload = ("SECRET"):rep(100000)})
field(huge_value, "payload", "string")
check(#huge_value < 1000 and not huge_value:find("SECRET", 1, true), "inspection expanded a large scalar value")

-- Existing overloads and function-identity aliases remain intact.
check(help(lush) == help("lush"), "shell namespace help changed")
check(help(ls) == help("ls") and help(lush.ls) == help("ls"), "function help changed")
local version_alias = version
check(help(version_alias) == help("version"), "documented function alias help changed")
local unknown_ok = pcall(help, callback)
check(not unknown_ok and calls == 1, "unknown function help invoked the function")
check(type(help()) == "string", "overview help changed")
local query_ok, query_error = pcall(help, {}, "extra")
check(not query_ok and type(query_error) == "string", "table help silently accepted a search query")
print("Help value checks passed: " .. checks)
