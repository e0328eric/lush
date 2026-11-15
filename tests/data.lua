-- Validate the structured-data library embedded in the executable.
assert(type(lush.data) == "table" and type(lush.stage) == "function", "embedded data library is missing")
local checks, null = 0, json.null
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
    checks = checks + 1
end
local function encoded(actual, expected)
    equal(json.encode(actual), expected)
end
local function rejects(callback, name)
    local ok, problem = pcall(callback)
    assert(not ok and tostring(problem):find(name, 1, true), tostring(problem))
    checks = checks + 1
end

for _, name in ipairs{"reverse", "uniq", "first", "last", "enumerate", "flatten", "append", "prepend",
    "columns", "reject", "rename", "update", "default", "any", "all", "reduce"} do
    equal(type(lush.Flow[name]), "function")
    equal(lush[name], _G[name])
    equal(lush.data[name], _G[name])
end

local values = {1, false, null, 2}
local original = json.encode(values)
encoded(stream(values):reverse():collect(), "[2,null,false,1]")
equal(json.encode(values), original)
equal(stream{}:reverse():count(), 0)
encoded(stream{1, 2, 3}:first():collect(), "[1]")
encoded(stream{1, 2, 3}:last():collect(), "[3]")
equal(getmetatable(stream{}:first()), lush.Flow)
equal(getmetatable(stream{}:last()), lush.Flow)
encoded(stream{1, 2, 3}:first(2):collect(), "[1,2]")
encoded(stream{1, 2, 3}:last(2):collect(), "[2,3]")
encoded(stream{1, 2, 3}:first(2.0):collect(), "[1,2]")
encoded(stream{1, 2, 3}:last(math.maxinteger):collect(), "[1,2,3]")
equal(stream{1, 2, 3}:first(0):count(), 0)
equal(stream{1, 2, 3}:last(0):count(), 0)
equal(stream{}:first():count(), 0)
equal(stream{}:last():count(), 0)
for _, value in ipairs{-1, 0.5, math.huge, -math.huge, 0 / 0, "2", false} do
    rejects(function() first(value) end, "first")
    rejects(function() last(value) end, "last")
end

encoded(stream{false, null}:enumerate():collect(), '[{"index":0,"item":false},{"index":1,"item":null}]')
encoded(stream{"a", "b"}:enumerate(-2):collect(), '[{"index":-2,"item":"a"},{"index":-1,"item":"b"}]')
equal(stream{"a"}:enumerate(math.maxinteger):collect()[1].index, math.maxinteger)
rejects(function() stream{"a", "b"}:enumerate(math.maxinteger):collect() end, "enumerate")
rejects(function() enumerate(0.25) end, "enumerate")
rejects(function() enumerate("0") end, "enumerate")
local nested = {{1, {2, 3}}, {4}, null, {name = "x"}, {}, json.object()}
encoded(stream(nested):flatten():collect(), '[1,[2,3],4,null,{"name":"x"},{}]')
encoded(nested[1], "[1,[2,3]]")

encoded(stream{1}:append{2, 3}:collect(), "[1,2,3]")
encoded(stream{1}:append(stream{2, false}):collect(), "[1,2,false]")
encoded(stream{1}:append(false):collect(), "[1,false]")
encoded(stream{1}:append(null):collect(), "[1,null]")
encoded(stream{1}:append{name = "x"}:collect(), '[1,{"name":"x"}]')
encoded(stream{1}:append(json.object()):collect(), '[1,{}]')
encoded(stream{3}:prepend{1, 2}:collect(), "[1,2,3]")
encoded(stream{3}:prepend(null):collect(), "[null,3]")
encoded(stream{3}:prepend(false):collect(), "[false,3]")
encoded(stream{1}:append{}:prepend{}:collect(), "[1]")
rejects(function() append() end, "append")
rejects(function() append(nil) end, "append")
rejects(function() prepend() end, "prepend")
rejects(function() prepend(nil) end, "prepend")

local rows = {{z = false}, {a = null}, {z = 1, b = 0}, {}}
encoded(stream(rows):columns():collect(), '["a","b","z"]')
encoded(stream{}:columns():collect(), "[]")
rejects(function() stream{1}:columns():collect() end, "columns")
rejects(function() stream{{1, 2}}:columns():collect() end, "columns")
rejects(function() stream{null}:columns():collect() end, "columns")
local record = {a = false, b = null, c = 0}
local before = json.encode(record)
local rejected = stream{record}:reject("a", "missing"):collect()[1]
encoded(rejected, '{"b":null,"c":0}')
equal(json.encode(record), before)
equal(rawequal(rejected, record), false)
encoded(stream{record}:reject("a", "b", "c"):collect()[1], "{}")
rejects(function() reject() end, "reject")
rejects(function() reject(1) end, "reject")
rejects(function() reject("a", nil) end, "reject")
rejects(function() stream{false}:reject("a"):collect() end, "reject")

encoded(stream{record}:rename("a", "x"):collect()[1], '{"b":null,"c":0,"x":false}')
encoded(stream{record}:rename("b", "x"):collect()[1], '{"a":false,"c":0,"x":null}')
encoded(stream{record}:rename("missing", "x"):collect()[1], before)
local same_name = stream{record}:rename("a", "a"):collect()[1]
encoded(same_name, before)
equal(rawequal(same_name, record), false)
rejects(function() stream{record}:rename("a", "b"):collect() end, "rename")
rejects(function() rename({a = "x"}) end, "rename")
rejects(function() rename("a", nil) end, "rename")
equal(json.encode(record), before)

local calls = 0
local updated = stream{{n = 2}, {}, {n = false}}:update("n", function(value, index)
    calls = calls + 1
    if value == null then return nil end
    if value == false then return false end
    return value + index
end)
equal(calls, 0)
encoded(updated:collect(), '[{"n":3},{"n":null},{"n":false}]')
equal(calls, 3)
local false_update = stream{record}:update("a", function() return true end):collect()[1]
equal(false_update.a, true)
equal(record.a, false)
rejects(function() update("n", 1) end, "update")
rejects(function() update(nil, function() end) end, "update")
rejects(function() stream{false}:update("n", function() end):collect() end, "update")
rejects(function() stream{{}}:update("n", function() error("callback failure") end):collect() end, "callback failure")
local default_rows = {{}, {x = null}, {x = false}, {x = 0}, {x = ""}}
encoded(stream(default_rows):default("x", 9):collect(), '[{"x":9},{"x":9},{"x":false},{"x":0},{"x":""}]')
encoded(default_rows, '[[],{"x":null},{"x":false},{"x":0},{"x":""}]')
encoded(stream{{}}:default("x", false):collect(), '[{"x":false}]')
encoded(stream{{}}:default("x", nil):collect(), '[{"x":null}]')
rejects(function() default("x") end, "default")
rejects(function() default(false, 1) end, "default")

calls = 0
local predicate = function(value) calls = calls + 1; return value > 1 end
local any_stage, all_stage = any(predicate), all(predicate)
equal(calls, 0)
equal(stream{1, 2, 3}:any(predicate), true)
equal(calls, 2)
calls = 0
equal(stream{1, 2, 3}:all(predicate), false)
equal(calls, 1)
equal(stream{}:any(predicate), false)
equal(stream{}:all(predicate), true)
equal(stream{false}:any(function() return 0 end), true)
equal(stream{false}:all(function() return nil end), false)
equal(stream{1, 2, 3} | any_stage, true)
equal(stream{2, 3} | all_stage, true)
rejects(function() any() end, "any")
rejects(function() all(false) end, "all")
equal(stream{1, 2, 3}:reduce(function(acc, item) return acc + item end, 0), 6)
equal(stream{2, 3}:reduce(function(acc, item, index) return acc + item * index end, 0), 8)
equal(stream{}:reduce(function() error("must not run") end, false), false)
equal(stream{}:reduce(function() error("must not run") end, nil), nil)
equal(stream{1, 2}:reduce(function(acc, item) return (acc or 0) + item end, nil), 3)
rejects(function() reduce(function() end) end, "reduce")
rejects(function() reduce(1, 0) end, "reduce")
equal(stream{1, 2, 3} | reduce(function(acc, item) return acc + item end, 0), 6)
encoded((stream{1, 2, 3} | reverse() | first(2) | enumerate()):collect(),
    '[{"index":0,"item":3},{"index":1,"item":2}]')

encoded(stream{1, 1.0, false, false, null, null, "1"}:uniq():collect(), '[1,false,null,"1"]')
encoded(stream{{a = 1, b = false}, {b = false, a = 1}, {a = 2}}:uniq():collect(),
    '[{"a":1,"b":false},{"a":2}]')
encoded(stream{{1, 2}, {1, 2}, {2, 1}}:uniq():collect(), '[[1,2],[2,1]]')
encoded(stream{json.object(), json.array(), json.object(), {}}:uniq():collect(), '[{},[]]')
local keyed = {{group = false, n = 1}, {group = false, n = 2}, {n = 3}, {group = null, n = 4}}
encoded(stream(keyed):uniq("group"):collect(), '[{"group":false,"n":1},{"n":3}]')
local cycle_a, cycle_b = {}, {}
cycle_a.self, cycle_b.self = cycle_a, cycle_b
equal(stream{cycle_a, cycle_b}:uniq():count(), 1)
local nan = 0 / 0
equal(stream{nan, nan}:uniq():count(), 2)
local trap = {__eq = function() error("uniq invoked __eq") end}
local marked_a, marked_b = setmetatable({x = 1}, trap), setmetatable({x = 1}, trap)
equal(stream{marked_a, marked_b}:uniq():count(), 1)
equal(stream{1, 1}:uniq():first():collect()[1], 1)
rejects(function() uniq(1) end, "uniq")
rejects(function() stream{1}:uniq("x"):collect() end, "uniq")

-- An external stage is converted to a lazy captured-byte source, without
-- evaluating the command while constructing a transform.
local original_execute = _lush.execute
calls = 0
_lush.execute = function(commands, input, capture_output)
    calls = calls + 1
    assert(capture_output == true and commands[1][1] == "data-fixture")
    return {ok = true, code = 0, signal = 0, stdout = "first\nsecond\n", stderr = "", statuses = {0}}
end
local ok, problem = xpcall(function()
    local pending = cmd["data-fixture"]() | last()
    equal(calls, 0)
    encoded(pending:collect(), '["first\\nsecond\\n"]')
    equal(calls, 1)
    encoded((cmd["data-fixture"]() | lines() | last()):collect(), '["second"]')
end, debug.traceback)
_lush.execute = original_execute
assert(ok, problem)
print("data: " .. checks .. " checks passed")
