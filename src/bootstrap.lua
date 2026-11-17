-- Lush's standard-Lua shell library. Operating-system work lives in Glosso.
local native = assert(_lush, "Lush native API is missing")
local lua_select, lua_type = select, type
-- Aliases may replace public Lua helper names. Builtin stream operations keep
-- their original helpers so command discovery cannot accidentally call one.
local getmetatable, setmetatable, pairs, ipairs, next, rawget, rawequal =
    getmetatable, setmetatable, pairs, ipairs, next, rawget, rawequal
local math = math
local tonumber, tostring, error = tonumber, tostring, error
local unpack = table.unpack
local function pack(...) return {n = lua_select("#", ...), ...} end

lush = lush or {}
lush.last_status = 0
lush.config = lush.config or {}
lush.execution_ms = 0

local Flow, Exec, Stage, Result = {}, {}, {}, {}
Flow.__index, Exec.__index, Stage.__index, Result.__index = Flow, Exec, Stage, Result
local ARRAY, OBJECT = {}, {}
local null = setmetatable({}, {__tostring = function() return "null" end})
local EXIT = {}
local execution_generation = 0
local function fail(message, level) error(message, (level or 1) + 1) end
local function checked(value, message)
    if value == nil then fail(message or "operation failed", 2) end
    return value
end
local function text(value, name)
    if lua_type(value) ~= "string" then fail((name or "argument") .. " must be a string", 2) end
    if value:find("\0", 1, true) then fail((name or "argument") .. " contains NUL", 2) end
    return value
end
local function path_arg(value, name)
    text(value, name or "path")
    if value:sub(1, 1) == "~" then return checked(native.path("home", value)) end
    return value
end
native.path_arg = path_arg
local function integer(value, name)
    if math.type(value) ~= "integer" or value < 0 then
        fail((name or "argument") .. " must be a nonnegative integer", 2)
    end
    return value
end
local function array(value)
    if lua_type(value) ~= "table" or value == null then return false end
    if getmetatable(value) == OBJECT then return false end
    local n = #value
    for i = 1, n do if rawget(value, i) == nil then return false end end
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > n then return false end
    end
    return true
end
local function keys(value)
    local result = {}
    for key in pairs(value) do result[#result + 1] = key end
    table.sort(result, function(a, b) return tostring(a) < tostring(b) end)
    return result
end

-- JSON is explicit at the boundary between records and external byte streams.
local json = {null = null}
local escapes = {["\""] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b",
                 ["\f"] = "\\f", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t"}
local function quote(value)
    if not utf8.len(value) then fail("JSON strings must contain valid UTF-8") end
    return '"' .. value:gsub('[%z\1-\31\\"]', function(c)
        return escapes[c] or string.format("\\u%04x", c:byte())
    end) .. '"'
end
function json.encode(value)
    local visiting = {}
    local function encode(item, depth)
        if depth > 256 then fail("JSON nesting exceeds 256 levels") end
        local kind = lua_type(item)
        if item == null or kind == "nil" then return "null" end
        if kind == "boolean" then return tostring(item) end
        if kind == "number" then
            if item ~= item or item == math.huge or item == -math.huge then
                fail("JSON cannot encode a non-finite number")
            end
            return tostring(item)
        end
        if kind == "string" then return quote(item) end
        if kind ~= "table" then fail("JSON cannot encode " .. kind) end
        if visiting[item] then fail("JSON cannot encode a cyclic table") end
        visiting[item] = true
        local out = {}
        if array(item) then
            for i = 1, #item do out[i] = encode(item[i], depth + 1) end
            visiting[item] = nil
            return "[" .. table.concat(out, ",") .. "]"
        end
        for _, key in ipairs(keys(item)) do
            if lua_type(key) ~= "string" then fail("JSON object keys must be strings") end
            out[#out + 1] = quote(key) .. ":" .. encode(item[key], depth + 1)
        end
        visiting[item] = nil
        return "{" .. table.concat(out, ",") .. "}"
    end
    return encode(value, 0)
end
function json.decode(source)
    if lua_type(source) ~= "string" then fail("JSON input must be bytes") end
    local at, length = 1, #source
    local function bad(message) fail("invalid JSON at byte " .. at .. ": " .. message, 2) end
    local function space()
        while at <= length and source:sub(at, at):match("[ \t\r\n]") do at = at + 1 end
    end
    local function hex4()
        local digits = source:sub(at, at + 3)
        if #digits ~= 4 or not digits:match("^%x%x%x%x$") then bad("expected four hex digits") end
        at = at + 4
        return tonumber(digits, 16)
    end
    local function string_value()
        at = at + 1
        local out, start = {}, at
        while at <= length do
            local c = source:sub(at, at)
            if c == '"' then
                out[#out + 1] = source:sub(start, at - 1)
                at = at + 1
                local result = table.concat(out)
                if not utf8.len(result) then bad("string contains invalid UTF-8") end
                return result
            elseif c == "\\" then
                out[#out + 1] = source:sub(start, at - 1)
                at = at + 1
                local escaped = source:sub(at, at)
                at = at + 1
                if escaped == "u" then
                    local code = hex4()
                    if code >= 0xd800 and code <= 0xdbff then
                        if source:sub(at, at + 1) ~= "\\u" then bad("missing low surrogate") end
                        at = at + 2
                        local low = hex4()
                        if low < 0xdc00 or low > 0xdfff then bad("invalid low surrogate") end
                        code = 0x10000 + (code - 0xd800) * 1024 + low - 0xdc00
                    elseif code >= 0xdc00 and code <= 0xdfff then bad("unexpected low surrogate") end
                    out[#out + 1] = utf8.char(code)
                else
                    local decoded = {['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b",
                                     f = "\f", n = "\n", r = "\r", t = "\t"}
                    if not decoded[escaped] then bad("invalid string escape") end
                    out[#out + 1] = decoded[escaped]
                end
                start = at
            elseif c:byte() < 32 then bad("control character in string")
            else at = at + 1 end
        end
        bad("unterminated string")
    end
    local value
    value = function(depth)
        if depth > 256 then bad("nesting exceeds 256 levels") end
        space()
        local c = source:sub(at, at)
        if c == '"' then return string_value() end
        if c == "[" or c == "{" then
            local object, finish = c == "{", c == "{" and "}" or "]"
            local result = setmetatable({}, object and OBJECT or ARRAY)
            at = at + 1
            space()
            if source:sub(at, at) == finish then at = at + 1; return result end
            while true do
                local key
                if object then
                    space()
                    if source:sub(at, at) ~= '"' then bad("expected object key") end
                    key = string_value()
                    space()
                    if source:sub(at, at) ~= ":" then bad("expected ':'") end
                    at = at + 1
                end
                local item = value(depth + 1)
                if object then result[key] = item else result[#result + 1] = item end
                space()
                c = source:sub(at, at)
                at = at + 1
                if c == finish then return result end
                if c ~= "," then bad("expected ',' or '" .. finish .. "'") end
            end
        end
        for token, item in pairs({["true"] = true, ["false"] = false, ["null"] = null}) do
            if source:sub(at, at + #token - 1) == token then at = at + #token; return item end
        end
        local start = at
        if c == "-" then at = at + 1 end
        c = source:sub(at, at)
        if c == "0" then at = at + 1
        elseif c:match("[1-9]") then
            repeat at = at + 1 until not source:sub(at, at):match("%d")
        else bad("expected a value") end
        if source:sub(at, at) == "." then
            at = at + 1
            if not source:sub(at, at):match("%d") then bad("missing fractional digits") end
            repeat at = at + 1 until not source:sub(at, at):match("%d")
        end
        c = source:sub(at, at)
        if c == "e" or c == "E" then
            at = at + 1
            c = source:sub(at, at)
            if c == "+" or c == "-" then at = at + 1 end
            if not source:sub(at, at):match("%d") then bad("missing exponent digits") end
            repeat at = at + 1 until not source:sub(at, at):match("%d")
        end
        local number = tonumber(source:sub(start, at - 1))
        if not number or number == math.huge or number == -math.huge then bad("number out of range") end
        return number
    end
    local result = value(0)
    space()
    if at <= length then bad("trailing input") end
    return result
end
json.array = function(value) return setmetatable(value or {}, ARRAY) end
json.object = function(value) return setmetatable(value or {}, OBJECT) end
lush.json, lush.null = json, null
_G.json = json

local function flow(value)
    if getmetatable(value) == Flow then return value end
    return setmetatable({resolve = function()
        if value == nil then return {} end
        return array(value) and value or {value}
    end}, Flow)
end
local function delayed(resolve) return setmetatable({resolve = resolve}, Flow) end
local function command(argv)
    if not array(argv) or #argv == 0 then fail("command requires a nonempty argument array", 2) end
    local copy = {}
    for i, arg in ipairs(argv) do
        if lua_type(arg) == "number" then arg = tostring(arg) end
        copy[i] = text(arg, "command argument " .. i)
    end
    if copy[1] == "" then fail("executable must not be empty", 2) end
    copy[1] = path_arg(copy[1], "executable")
    return setmetatable({commands = {copy}}, Exec)
end
local function argv_call(name, ...)
    local args = {text(name, "executable")}
    for i = 1, lua_select("#", ...) do
        local arg = lua_select(i, ...)
        if arg == nil then fail("command arguments must not be nil", 2) end
        args[#args + 1] = arg
    end
    return command(args)
end
local function execute(plan, capture_output, input)
    if getmetatable(plan) ~= Exec then fail("expected an external command or pipeline", 2) end
    if input == nil then input = plan.input end
    if input ~= nil and lua_type(input) ~= "string" then fail("process input must be bytes", 2) end
    -- Lua's buffered output and the child's inherited OS handles must agree
    -- about ordering when stdout/stderr point at files or pipes.
    checked(io.stdout:flush())
    checked(io.stderr:flush())
    local result = checked(native.execute(plan.commands, input, capture_output))
    execution_generation = execution_generation + 1
    lush.last_status = result.code or 1
    if result.error and result.error ~= "" then fail(result.error, 2) end
    return setmetatable(result, Result)
end
function Result:check()
    if not self.ok then fail("command failed (exit " .. tostring(self.code) .. ")", 2) end
    return self
end
function Result:lines() return flow(self.stdout):lines() end
function Result:from_json() return flow(json.decode(self.stdout)) end
function Exec:run() return execute(self, false) end
function Exec:capture(input) return execute(self, true, input) end
local function bytes(value)
    local meta = getmetatable(value)
    if meta == Exec then return execute(value, true):check().stdout end
    if meta == Result then return value:check().stdout end
    if meta == Flow then
        local values = value:collect()
        if #values == 1 and lua_type(values[1]) == "string" then return values[1] end
    end
    if lua_type(value) ~= "string" then
        fail("external input requires bytes; encode records with to.json() or to_json()", 2)
    end
    return value
end
function Flow:collect()
    local values = self.resolve()
    if not array(values) then fail("structured stream producer must return an array", 2) end
    return values
end
local function as_flow(value)
    if getmetatable(value) == Exec then return delayed(function() return {bytes(value)} end) end
    return flow(value)
end
function Flow:where(predicate)
    if lua_type(predicate) ~= "function" then fail("where requires a Lua function", 2) end
    return delayed(function()
        local result = {}
        for i, item in ipairs(self:collect()) do
            if predicate(item, i) then result[#result + 1] = item end
        end
        return result
    end)
end
Flow.filter = Flow.where
function Flow:map(callback)
    if lua_type(callback) ~= "function" then fail("each requires a Lua function", 2) end
    return delayed(function()
        local result = {}
        for i, item in ipairs(self:collect()) do
            local mapped = callback(item, i)
            if mapped ~= nil then result[#result + 1] = mapped end
        end
        return result
    end)
end
Flow.each = Flow.map
function Flow:foreach(callback)
    if lua_type(callback) ~= "function" then fail("foreach requires a Lua function", 2) end
    for i, item in ipairs(self:collect()) do callback(item, i) end
end
function Flow:select(...)
    local fields = {...}
    if #fields == 0 then fail("select requires one or more field names", 2) end
    for _, field in ipairs(fields) do text(field, "field") end
    return self:map(function(item)
        if lua_type(item) ~= "table" then fail("select requires records") end
        local result = setmetatable({}, OBJECT)
        for _, field in ipairs(fields) do result[field] = item[field] == nil and null or item[field] end
        return result
    end)
end
function Flow:get(field)
    text(field, "field")
    return self:map(function(item)
        if lua_type(item) ~= "table" then fail("get requires records") end
        local value = item[field]
        return value == nil and null or value
    end)
end
function Flow:take(count)
    integer(count, "take count")
    return delayed(function()
        local values, result = self:collect(), {}
        for i = 1, math.min(count, #values) do result[i] = values[i] end
        return result
    end)
end
function Flow:skip(count)
    integer(count, "skip count")
    return delayed(function()
        local values, result = self:collect(), {}
        for i = count + 1, #values do result[#result + 1] = values[i] end
        return result
    end)
end
function Flow:sort_by(field, descending)
    if lua_type(field) ~= "string" and lua_type(field) ~= "function" then
        fail("sort_by requires a field name or Lua function", 2)
    end
    return delayed(function()
        local sorted = {}
        for i, item in ipairs(self:collect()) do
            local key
            if lua_type(field) == "function" then key = field(item)
            elseif lua_type(item) == "table" then key = item[field]
            else fail("sorting scalar values requires a Lua key function") end
            sorted[i] = {value = item, key = key, index = i}
        end
        table.sort(sorted, function(a, b)
            if a.key == b.key then return a.index < b.index end
            local left, right = a.key, b.key
            if (left == nil or left == null) and (right == nil or right == null) then
                return a.index < b.index
            end
            if left == nil or left == null then return not descending end
            if right == nil or right == null then return not not descending end
            if lua_type(left) ~= lua_type(right) or (lua_type(left) ~= "number" and lua_type(left) ~= "string") then
                left, right = tostring(left), tostring(right)
            end
            if descending then return left > right end
            return left < right
        end)
        local result = {}
        for i, item in ipairs(sorted) do result[i] = item.value end
        return result
    end)
end
function Flow:count() return #self:collect() end
function Flow:to_json() return json.encode(self:collect()) end
function Flow:lines()
    return delayed(function()
        local result = {}
        for _, item in ipairs(self:collect()) do
            if lua_type(item) ~= "string" then fail("lines requires bytes or strings") end
            local at = 1
            while at <= #item do
                local finish = item:find("\n", at, true)
                local line = finish and item:sub(at, finish - 1) or item:sub(at)
                result[#result + 1] = line:gsub("\r$", "")
                if not finish then break end
                at = finish + 1
            end
        end
        return result
    end)
end
function Exec:lines() return as_flow(self):lines() end
function Exec:from_json() return delayed(function() return flow(json.decode(bytes(self))):collect() end) end

local function stage(apply) return setmetatable({apply = apply}, Stage) end
local function connect(left, right)
    if getmetatable(left) == Stage and getmetatable(right) == Stage then
        return stage(function(input) return right.apply(left.apply(input)) end)
    end
    if getmetatable(right) == Stage then return right.apply(left) end
    if getmetatable(right) == Exec then
        if getmetatable(left) == Exec then
            if right.input then fail("cannot pipe to a command with its own input") end
            local stages = {}
            for _, argv in ipairs(left.commands) do stages[#stages + 1] = argv end
            for _, argv in ipairs(right.commands) do stages[#stages + 1] = argv end
            return setmetatable({commands = stages, input = left.input}, Exec)
        end
        return setmetatable({commands = right.commands, input = bytes(left)}, Exec)
    end
    if lua_type(right) == "function" then return right(left) end
    fail("pipeline stage must be a command or a transform such as where(...)", 2)
end
Flow.__bor, Exec.__bor, Stage.__bor = connect, connect, connect

function run(value, ...)
    if getmetatable(value) ~= Exec then
        if lua_type(value) == "string" then value = argv_call(value, ...)
        else value = command(value) end
    end
    return execute(value, false)
end
function capture(value, ...)
    if getmetatable(value) ~= Exec then
        if lua_type(value) == "string" then value = argv_call(value, ...)
        else value = command(value) end
    end
    return execute(value, true)
end
function pipe(value, ...)
    if lua_select("#", ...) == 0 and array(value) then
        if #value == 0 then fail("pipe requires at least one stage") end
        local result = value[1]
        for i = 2, #value do result = connect(result, value[i]) end
        return result
    end
    for i = 1, lua_select("#", ...) do value = connect(value, lua_select(i, ...)) end
    return value
end
stream = flow
function where(predicate) return stage(function(value) return as_flow(value):where(predicate) end) end
filter = where
function each(callback) return stage(function(value) return as_flow(value):map(callback) end) end
map = each
function select(first, ...)
    if first == "#" or lua_type(first) == "number" or
        (lua_type(first) == "string" and tonumber(first) ~= nil) then
        return lua_select(first, ...)
    end
    local fields = {first, ...}
    return stage(function(value) return as_flow(value):select(unpack(fields)) end)
end
function get(field) return stage(function(value) return as_flow(value):get(field) end) end
function take(count) return stage(function(value) return as_flow(value):take(count) end) end
function skip(count) return stage(function(value) return as_flow(value):skip(count) end) end
function sort_by(field, descending) return stage(function(value) return as_flow(value):sort_by(field, descending) end) end
function lines(value)
    if value == nil then return stage(function(input) return as_flow(input):lines() end) end
    return as_flow(value):lines()
end
function collect(value)
    if value == nil then return stage(function(input) return as_flow(input):collect() end) end
    return as_flow(value):collect()
end
function count(value)
    if value == nil then return stage(function(input) return as_flow(input):count() end) end
    return as_flow(value):count()
end
function to_json(value)
    if value == nil then return stage(function(input)
        if getmetatable(input) == Flow then input = input:collect() end
        return json.encode(input)
    end) end
    if getmetatable(value) == Flow then value = value:collect() end
    return json.encode(value)
end
function from_json(value)
    if value == nil then return stage(function(input) return flow(json.decode(bytes(input))) end) end
    return flow(json.decode(bytes(value)))
end
function to_text(value)
    local function encode(input)
        if getmetatable(input) ~= Flow and lua_type(input) == "string" then return input end
        local out = {}
        for i, item in ipairs(as_flow(input):collect()) do
            if lua_type(item) == "table" then fail("records require an explicit JSON encoding") end
            out[i] = tostring(item) .. "\n"
        end
        return table.concat(out)
    end
    if value == nil then return stage(encode) end
    return encode(value)
end
from, to = {json = from_json}, {json = to_json, text = to_text}
from.lines, from_lines = lines, lines
function ls(...)
    local values, arguments = pack(...), {}
    if values.n == 1 and values[1] == nil then values.n = 0 end
    -- Keep the original ls(path, all) API alongside fls-style argument strings.
    if values.n == 2 and (values[2] == nil or lua_type(values[2]) == "boolean") then
        if values[2] then arguments[#arguments + 1] = "-a" end
        arguments[#arguments + 1] = "--"
        arguments[#arguments + 1] = text(values[1] or ".", "path")
    else
        for i = 1, values.n do arguments[i] = text(values[i], "ls argument " .. i) end
    end
    local result = delayed(function() return checked(native.fls_records(arguments)) end)
    result.fls_arguments = arguments
    return result
end
function sl(...)
    return ls("--lol", ...)
end
function pwd()
    local directory = checked(native.cwd())
    if native.platform == "windows" then directory = directory:gsub("\\", "/") end
    return directory
end
function echo(...)
    local values = {}
    for i = 1, lua_select("#", ...) do values[i] = tostring(lua_select(i, ...)) end
    io.write(table.concat(values, " "), "\n")
end
function cd(path)
    if path == nil then path = "~" end
    checked(native.cd(path_arg(path, "directory")))
end
function cat(path)
    return checked(native.read(path_arg(path)))
end
function open(target)
    target = path_arg(target, "open target")
    if target == "" then fail("open target must not be empty") end
    return checked(native.open(target))
end
function save(path, append)
    path = path_arg(path)
    return stage(function(input) checked(native.write(path, bytes(input), not not append)); return nil end)
end
env = setmetatable({}, {
    __index = function(_, name)
        local value, message = native.env_get(text(name, "environment name"))
        if value == nil and message then fail(message) end
        return value
    end,
    __newindex = function(_, name, value)
        if value ~= nil then text(value, "environment value") end
        checked(native.env_set(text(name, "environment name"), value))
    end,
})
cmd = setmetatable({}, {
    __index = function(_, name)
        return function(...)
            return argv_call(name, ...)
        end
    end,
    __call = function(_, name, ...) return argv_call(name, ...) end,
})
function exit(code)
    code = code or lush.last_status or 0
    if math.type(code) ~= "integer" or code < 0 or code > 255 then fail("exit code must be between 0 and 255") end
    lush.exit_requested, lush.exit_code = true, code
    native.request_exit(code)
    error(EXIT, 0)
end

local function cell(value)
    if value == null then return "null" end
    if lua_type(value) == "table" then
        local ok, encoded = pcall(json.encode, value)
        return ok and encoded or "<table>"
    end
    return tostring(value)
end
local function safe_display(value)
    return cell(value):gsub("[%z\1-\8\11\12\14-\31\127]", function(c)
        return string.format("\\x%02x", c:byte())
    end):gsub("\n", "\\n"):gsub("\r", "\\r"):gsub("\t", "\\t")
end
function lush.display(value)
    if value == nil then return end
    local meta = getmetatable(value)
    if meta == Exec then execute(value, false); return end
    if meta == Result then
        if value.stdout and #value.stdout > 0 then io.write(value.stdout) end
        if value.stderr and #value.stderr > 0 then io.stderr:write(value.stderr) end
        return
    end
    if meta == Flow then
        if value.fls_arguments then
            checked(io.stdout:flush())
            checked(io.stderr:flush())
            lush.last_status = checked(native.fls(value.fls_arguments))
            execution_generation = execution_generation + 1
            return
        end
        value = value:collect()
    end
    if lua_type(value) ~= "table" or value == null then print(cell(value)); return end
    if not array(value) then
        for _, key in ipairs(keys(value)) do print(safe_display(key) .. "  " .. safe_display(value[key])) end
        return
    end
    if #value == 0 then return end
    local records = true
    for _, row in ipairs(value) do
        if lua_type(row) ~= "table" or row == null or array(row) then records = false; break end
    end
    if not records then for _, row in ipairs(value) do print(cell(row)) end; return end
    local columns, seen = {}, {}
    -- Common filesystem fields are more useful in this order than alphabetically.
    for _, key in ipairs({"name", "type", "size", "modified"}) do
        for _, row in ipairs(value) do
            if row[key] ~= nil then columns[#columns + 1] = key; seen[key] = true; break end
        end
    end
    for _, row in ipairs(value) do
        for _, key in ipairs(keys(row)) do
            if not seen[key] then columns[#columns + 1] = key; seen[key] = true end
        end
    end
    local widths, rows = {}, {}
    for i, key in ipairs(columns) do widths[i] = #safe_display(key) end
    for r, row in ipairs(value) do
        rows[r] = {}
        for i, key in ipairs(columns) do
            local item = row[key]
            rows[r][i] = item == nil and "" or safe_display(item)
            widths[i] = math.max(widths[i], #rows[r][i])
        end
    end
    local function row_line(row)
        local out = {}
        for i, item in ipairs(row) do
            out[i] = item .. string.rep(" ", i == #row and 0 or widths[i] - #item + 2)
        end
        print(table.concat(out))
    end
    local header = {}
    for i, key in ipairs(columns) do header[i] = safe_display(key) end
    row_line(header)
    for _, row in ipairs(rows) do row_line(row) end
end
function lush.dispatch(value) lush.display(value) end
show = lush.display
function help()
    return [[Lush: Lua programming with structured shell pipelines.

  ls() | where(function(f) return f.size > 1024 end) | select('name', 'size')
  cmd.git('log', 'main') | lines() | take(5)
  cmd.git('status')                 -- a lazy external command
  run{'git', 'status'}              -- execute with terminal input/output
  capture{'git', 'status'}.stdout   -- capture bytes and exit status
  ls():sort_by('size', true):take(5)
  ls('-la', '.')                    -- fls-style display and options
  ls('--lol')                       -- fls takeoff animation; also sl()
  show(ls() | to.json() | save('files.json'))

Builtins: ls, sl, pwd, cd, echo, cat, open, save, env, exit, help.
Transforms: where, select, get, each, take, skip, sort_by, lines, count, collect.
Use Lua functions for control flow and filtering. External arguments stay separate.
Globals persist between prompt submissions; Lua locals belong to their chunk.]]
end

function lush.prompt()
    if lua_type(lush.config.prompt) == "function" then
        local value = lush.config.prompt()
        return lua_type(value) == "table" and value or tostring(value)
    end
    if lua_type(lush.config.prompt) == "string" then return lush.config.prompt end
    if lua_type(lush.config.prompt) == "table" then return lush.config.prompt end
    local selected = lush.config.theme
    if lush.theme and selected ~= nil and selected ~= false and selected ~= "plain" then
        local options = lush.config.theme_options or {}
        assert(lua_type(options) == "table", "lush.config.theme_options must be a table")
        if lua_type(selected) == "string" then
            local custom = lush.config.themes
            assert(custom == nil or lua_type(custom) == "table", "lush.config.themes must be a table")
            local name = selected
            selected = custom and rawget(custom, name)
            if selected == nil then
                local message
                selected, message = lush.theme.load(name)
                assert(selected ~= nil, "unknown prompt theme: " .. name .. (message and "; " .. message or ""))
            end
        end
        assert(lua_type(selected) == "function" or
            (lua_type(selected) == "table" and rawget(selected, "kind") == "prompt"),
            "expected a prompt descriptor or builder for prompt theme")
        local context = native.prompt_context(options.git ~= false, true)
        context.last_status, context.execution_ms = lush.last_status, lush.execution_ms
        context.time = os.date("%H:%M:%S")
        if lua_type(selected) == "function" then selected = selected(context, options) end
        local rendered = lush.theme.render(selected, context, options)
        if #rendered.lines == 0 then return rendered.input end
        return rendered
    end
    local directory = native.cwd() or "?"
    local home = native.path("home", "~")
    if home and directory:sub(1, #home) == home and
        (#directory == #home or directory:sub(#home + 1, #home + 1):match("[/\\]")) then
        directory = "~" .. directory:sub(#home + 1)
    end
    return directory .. " > "
end
function lush.complete(prefix)
    local names = {"ls", "pwd", "cd", "echo", "cat", "open", "save", "env", "exit", "help", "cmd.",
                   "where", "select", "get", "each", "take", "sort_by", "lines", "count", "to.json", "from.json"}
    local result = {}
    for _, name in ipairs(names) do if name:sub(1, #prefix) == prefix then result[#result + 1] = name end end
    table.sort(result)
    return result
end
local function compile_submission(source, name)
    local chunk, expression_error = load("return " .. source, name, "t", _G)
    local expression = chunk ~= nil
    local statement_error
    if not chunk then chunk, statement_error = load(source, name, "t", _G) end
    if not chunk then
        local message = statement_error or expression_error
        local incomplete = message and message:match("<eof>$") ~= nil
        -- An input can be a partial expression even when it cannot start a Lua
        -- statement, e.g. `1 +`. Match Lua's own REPL EOF marker, not a filename
        -- or a quoted token which happens to contain the same characters.
        if not incomplete and expression_error and expression_error:match("<eof>$") then
            incomplete = true
        end
        return nil, false, message, incomplete
    end
    return chunk, expression, nil, false
end
-- Parsing separately lets the interactive host save complete commands before
-- execution, including commands which call Lua's immediate os.exit().
function lush.check(source, name)
    local chunk, _, message, incomplete = compile_submission(source, name or "=stdin")
    return chunk ~= nil, message, incomplete
end
function lush.eval(source, name, display)
    local chunk, expression, message, incomplete = compile_submission(source, name or "=stdin")
    if not chunk then
        lush.last_status = 1
        return false, message, incomplete
    end
    local previous_generation = execution_generation
    local values
    local ok, message = xpcall(function()
        values = pack(chunk())
        if display and expression then
            for i = 1, values.n do lush.display(values[i]) end
        end
    end, function(message)
        if message == EXIT then return EXIT end
        return debug.traceback(tostring(message), 2)
    end)
    if message == EXIT then return true, nil, false end
    if not ok then lush.last_status = 1; return false, message, false end
    -- Preserve the previous status while the chunk runs, so exit() without an
    -- explicit code can use it. Successful Lua-only submissions then clear it.
    if execution_generation == previous_generation then lush.last_status = 0 end
    return true, nil, false
end

lush.Flow, lush.Exec, lush.Result = Flow, Exec, Result
lush.run, lush.capture, lush.pipe, lush.stream = run, capture, pipe, stream
lush.stage = stage
lush.ls, lush.sl, lush.pwd, lush.cd, lush.env, lush.cmd = ls, sl, pwd, cd, env, cmd
lush.echo, lush.exit, lush.help = echo, exit, help
lush.where, lush.select, lush.get, lush.each = where, select, get, each
lush.filter, lush.map = filter, map
lush.take, lush.skip, lush.sort_by = take, skip, sort_by
lush.lines, lush.collect, lush.count = lines, collect, count
lush.to_json, lush.from_json, lush.to_text, lush.show = to_json, from_json, to_text, show
lush.cat, lush.open, lush.read = cat, open, cat
lush.write = function(path, contents, append)
    return checked(native.write(path_arg(path), contents, not not append))
end
package.loaded.lush = lush
