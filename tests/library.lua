-- Pure-Lua regressions for the library embedded by the Glosso executable.
-- Run with: build/lush --no-config tests/library.lua
local checks = 0
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
    checks = checks + 1
end
local function rejects(callback, message)
    local ok, problem = pcall(callback)
    assert(not ok and tostring(problem):find(message, 1, true), tostring(problem))
    checks = checks + 1
end
local function evaluation(source, expected_ok, expected_incomplete, filename)
    local ok, message, incomplete = lush.eval(source, filename or "=(library test)", false)
    equal(ok, expected_ok)
    equal(incomplete, expected_incomplete)
    if not ok then assert(type(message) == "string" and #message > 0) end
    return message
end

equal(require("lush"), lush)
equal(1 | 2, 3)
equal(select("#", nil, false, 4), 3)
equal(select(2, "one", "two"), "two")
equal(select("2", "one", "two"), "two")

evaluation("1 +", false, true)
evaluation("if true then", false, true)
evaluation("local function unfinished()", false, true)
evaluation("local text = [=[unfinished", false, true)
evaluation("'unfinished", false, true)
evaluation("local =", false, false, "@filename-<eof>.lua")
evaluation("local x = )", false, false)
evaluation("function broken(]", false, false)
evaluation("'line\nbreak'", false, false)
evaluation("error({reason = 'table errors still have a diagnostic'})", false, false)
evaluation("error(false)", false, false)
evaluation("local hidden = 42; library_persistent = 7", true, false)
equal(hidden, nil)
equal(library_persistent, 7)
evaluation("assert(library_persistent == 7)", true, false)
evaluation("git status", false, false)
evaluation("return '\27Lua binary strings are ordinary data'", true, false)

local data = stream{
    {name = "z", size = 9, present = false},
    {name = "a", size = 1, present = true},
    {name = "m", size = 4},
}
local filtered = (data | where(function(row) return row.size > 1 end)
    | sort_by("name") | select("name", "present")):collect()
equal(#filtered, 2)
equal(filtered[1].name, "m")
equal(filtered[1].present, json.null)
equal(filtered[2].present, false)
equal(data:take(0):count(), 0)
equal(data:skip(1):count(), 2)
equal(data:count(), 3)
equal(stream{1, 2, 3}:where(function() return 0 end):count(), 3)
equal(stream{1, 2, 3}:map(function(n) return n == 2 and false or n end):count(), 3)
local booleans = stream{false, true, false}:sort_by(function(value) return value end):collect()
equal(booleans[1], false)
equal(booleans[3], true)
local absent = stream{{index = 1}, {index = 2, value = json.null}, {index = 3, value = 0}}
    :sort_by("value"):collect()
equal(absent[1].index, 1)
equal(absent[2].index, 2)
equal(absent[3].index, 3)
local stages = where(function(row) return row.size >= 4 end) | select("name")
equal((data | stages):count(), 2)
equal(pipe{data, take(2), count()}, 2)
equal((stream{"a", "b"} | to.text()), "a\nb\n")
local separated = from_lines("a\r\nb\n\n"):collect()
equal(#separated, 3)
equal(separated[1], "a")
equal(separated[2], "b")
equal(separated[3], "")
equal(from_lines(""):count(), 0)
equal(from_lines("\n"):count(), 1)
rejects(function() data:take(-1) end, "nonnegative integer")
rejects(function() data:where("size") end, "Lua function")
rejects(function() return (data | cmd("unused")) end, "encode records")
rejects(function() return data | to.text() end, "JSON")

local roundtrip = {
    object = json.object(),
    list = json.array(),
    missing = json.null,
    text = 'quote " slash \\ newline\n NUL\0 snowman \226\152\131',
    truth = true,
    lie = false,
    number = -12.25e3,
}
local restored = json.decode(json.encode(roundtrip))
equal(restored.text, roundtrip.text)
equal(restored.missing, json.null)
equal(restored.truth, true)
equal(restored.lie, false)
equal(restored.number, roundtrip.number)
equal(json.encode(restored.object), "{}")
equal(json.encode(restored.list), "[]")
equal(json.encode(json.decode("{}")), "{}")
equal(json.encode(json.decode("[]")), "[]")
equal(json.encode(json.decode("null")), "null")
equal(json.encode(json.decode("false")), "false")
equal(json.decode('"\\ud83d\\ude00"'), utf8.char(0x1f600))
equal((from.json('[{"x":false},null]')):collect()[1].x, false)
equal((from_json('[{"x":false},null]')):collect()[2], json.null)
for _, malformed in ipairs({"", "[1,]", '{"x":}', "01", "+1", "1.", "1e", "NaN",
    '"\\ud800"', '"\\udc00"', '"\\uqqqq"', '"\\x"', '"raw\nnewline"', '"\255"'}) do
    rejects(function() json.decode(malformed) end, "JSON")
end
rejects(function() json.encode(0 / 0) end, "non-finite")
rejects(function() json.encode(math.huge) end, "non-finite")
rejects(function() json.encode("\255") end, "UTF-8")
local cycle = {}; cycle.self = cycle
rejects(function() json.encode(cycle) end, "cyclic")
rejects(function() json.encode({[false] = "invalid key"}) end, "keys must be strings")
local nested = {}
for _ = 1, 260 do nested = {nested} end
rejects(function() json.encode(nested) end, "nesting")
rejects(function() json.decode(string.rep("[", 260) .. string.rep("]", 260)) end, "nesting")

rejects(function() cmd.git("a", nil, "b") end, "must not be nil")
rejects(function() cmd("git", nil) end, "must not be nil")
rejects(function() run("git", nil) end, "must not be nil")
rejects(function() capture{"git", [3] = "sparse"} end, "nonempty argument array")
rejects(function() cmd.git("\0") end, "NUL")
rejects(function() cmd("") end, "empty")
rejects(function() cmd.git({}) end, "must be a string")
rejects(function() cmd.git():capture(42) end, "input must be bytes")
rejects(function() ls("\0") end, "NUL")
rejects(function() env["\0"] = "value" end, "NUL")
rejects(function() exit(256) end, "between 0 and 255")
local standard_output, standard_error = io.stdout, io.stderr
io.stdout = {flush = function() return nil, "deliberate stdout flush failure" end}
rejects(function() run{"must-not-launch"} end, "deliberate stdout flush failure")
io.stdout = standard_output
io.stderr = {flush = function() return nil, "deliberate stderr flush failure" end}
rejects(function() run{"must-not-launch"} end, "deliberate stderr flush failure")
io.stderr = standard_error

-- A successful submission clears an earlier Lua failure status.
evaluation("error('expected')", false, false)
equal(lush.last_status, 1)
evaluation("assert(true)", true, false)
equal(lush.last_status, 0)

-- Requests survive pcall, even though pcall deliberately catches the private
-- unwind error. Reset the request to zero before this test process finishes.
local ok = pcall(exit, 6)
equal(ok, false)
equal(lush.exit_requested, true)
equal(lush.exit_code, 6)
lush.last_status = 7
evaluation("exit(); error('unreachable')", true, false)
equal(lush.exit_code, 7)
evaluation("exit(0); error('unreachable')", true, false)
equal(lush.exit_code, 0)
print("library: " .. checks .. " checks passed")
