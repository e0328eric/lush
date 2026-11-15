-- Trusted bootstrap for the dedicated theme VM. No shell state is installed
-- here; the native bridge opens only base, string, math, table and UTF-8 libs.
local host_globals, original_theme = _G, assert(lush.theme)
local lua_type, lua_error, lua_next, lua_pairs = type, error, next, pairs
local lua_select, lua_tostring, lua_pcall = select, tostring, pcall
local lua_rawget, lua_getmetatable, lua_load = rawget, getmetatable, load
local pack, unpack = table.pack, table.unpack
local string_functions, table_functions, utf8_functions = {}, {}, {}
for key, value in lua_next, string do string_functions[key] = value end
for key, value in lua_next, table do table_functions[key] = value end
for key, value in lua_next, utf8 do utf8_functions[key] = value end
local string_meta = lua_getmetatable("")
local original_methods = string_meta.__index
local finite, integer = math.huge, math.type
local MAX_STRING, MAX_RESULT, MAX_ITEMS = 16384, 65536, 4096

local function fail(message) lua_error("theme sandbox: " .. message, 0) end
local function message(value)
    local kind = lua_type(value)
    return (kind == "string" or kind == "number") and lua_tostring(value) or ("Lua raised a " .. kind .. " error")
end
local function data(value)
    local active, copied, count, bytes = {}, {}, 0, 0
    local function copy(item, depth)
        count = count + 1
        if count > MAX_ITEMS then fail("data contains too many items") end
        local kind = lua_type(item)
        if kind == "nil" or kind == "boolean" then return item end
        if kind == "number" then
            if item ~= item or item == finite or item == -finite then fail("data must contain finite numbers") end
            return item
        end
        if kind == "string" then
            bytes = bytes + #item
            if #item > MAX_RESULT or bytes > 262144 then fail("data is too large") end
            return item
        end
        if kind ~= "table" then fail("data cannot contain " .. kind .. " values") end
        if depth > 32 then fail("data is nested too deeply") end
        if lua_getmetatable(item) ~= nil then fail("data cannot have metatables") end
        if active[item] then fail("data cannot contain cycles") end
        if copied[item] then return copied[item] end
        local result = {}
        copied[item], active[item] = result, true
        for key, child in lua_next, item do
            local key_kind = lua_type(key)
            if key_kind ~= "string" and key_kind ~= "number" and key_kind ~= "boolean" then
                fail("data keys must be strings, numbers or booleans")
            end
            result[copy(key, depth + 1)] = copy(child, depth + 1)
        end
        active[item] = nil
        return result
    end
    return copy(value, 1)
end
local function text(value)
    if lua_type(value) ~= "string" then fail("expected a string") end
    if #value > MAX_STRING then fail("string input is too large") end
    return value
end
local function checked_results(...)
    for index = 1, lua_select("#", ...) do
        local value = lua_select(index, ...)
        if lua_type(value) == "string" and #value > MAX_RESULT then fail("string result is too large") end
    end
    return ...
end
local function string_call(fn, ...)
    if lua_select("#", ...) > MAX_ITEMS then fail("too many arguments") end
    for index = 1, lua_select("#", ...) do
        local value = lua_select(index, ...)
        if lua_type(value) == "string" then text(value) end
    end
    return checked_results(fn(...))
end

local safe_string = {}
for _, name in ipairs{"byte", "char", "format", "len", "lower", "pack", "packsize", "reverse", "sub", "unpack", "upper"} do
    local fn = string_functions[name]
    safe_string[name] = function(...) return string_call(fn, ...) end
end
function safe_string.find(value, needle, start, plain)
    text(value); text(needle)
    if plain ~= nil and plain ~= true then fail("string.find supports literal search only") end
    return string_functions.find(value, needle, start, true)
end
function safe_string.rep(value, times, separator)
    text(value)
    if separator ~= nil then text(separator) end
    if integer(times) ~= "integer" then fail("string.rep count must be an integer") end
    local count = math.max(0, times)
    local size = #value * count + #(separator or "") * math.max(0, count - 1)
    -- Division avoids integer-overflow tricks in the output-size calculation.
    if count > MAX_RESULT or (#value + #(separator or "")) > 0 and
        count > (MAX_RESULT + #(separator or "")) / (#value + #(separator or "")) or size > MAX_RESULT then
        fail("string result is too large")
    end
    return string_functions.rep(value, times, separator)
end
local safe_methods = {}
for key, value in lua_next, safe_string do safe_methods[key] = value end
string_meta.__index = safe_methods

local function count_range(first, last)
    if integer(first) ~= "integer" or integer(last) ~= "integer" then fail("table range must use integers") end
    if last >= first and (last - first < 0 or last - first >= MAX_ITEMS) then fail("table range is too large") end
end
local function list(value)
    if lua_type(value) ~= "table" then fail("expected a table") end
    if #value > MAX_ITEMS then fail("table sequence is too large") end
    return value
end
local safe_table = {}
function safe_table.pack(...)
    if lua_select("#", ...) > MAX_ITEMS then fail("too many arguments") end
    return pack(...)
end
function safe_table.unpack(value, first, last)
    list(value)
    first, last = first or 1, last or #value
    count_range(first, last)
    return unpack(value, first, last)
end
function safe_table.move(value, first, last, target, destination)
    list(value)
    if destination ~= nil then list(destination) end
    count_range(first, last)
    return table_functions.move(value, first, last, target, destination)
end
function safe_table.concat(value, separator, first, last)
    list(value)
    first, last = first or 1, last or #value
    count_range(first, last)
    if separator ~= nil then text(separator) end
    return checked_results(table_functions.concat(value, separator, first, last))
end
for _, name in ipairs{"insert", "remove", "sort"} do
    local fn = table_functions[name]
    safe_table[name] = function(value, ...) list(value); return fn(value, ...) end
end
local safe_utf8 = {charpattern = utf8_functions.charpattern}
for _, name in ipairs{"char", "codepoint", "len", "offset", "codes"} do
    local fn = utf8_functions[name]
    safe_utf8[name] = function(...) return string_call(fn, ...) end
end
local safe_math = {}
for key, value in lua_next, math do safe_math[key] = value end

local safe_theme = {}
for _, name in ipairs{"text", "os", "path", "git", "session", "time", "status", "execution_time",
    "python", "battery", "root", "memory", "separator", "chain", "row", "prompt", "render", "render_components", "sanitize"} do
    local fn = original_theme[name]
    safe_theme[name] = function(...)
        local arguments = data(pack(...))
        -- Constructors/rendering use fixed, trusted patterns internally. The
        -- arguments contain only plain data, so no user callback can run while
        -- the dedicated VM's original string methods are temporarily active.
        string_meta.__index = original_methods
        local result = pack(lua_pcall(fn, unpack(arguments, 1, arguments.n)))
        string_meta.__index = safe_methods
        if not result[1] then fail(message(result[2])) end
        local values = {}
        for index = 2, result.n do values[index - 1] = data(result[index]) end
        return unpack(values, 1, result.n - 1)
    end
end

local environment = {
    _VERSION = _VERSION, assert = assert, error = error, ipairs = ipairs,
    next = lua_next, pairs = lua_pairs, select = lua_select, tonumber = tonumber,
    tostring = lua_tostring, type = lua_type, rawequal = rawequal, rawget = lua_rawget, rawlen = rawlen,
    string = safe_string, table = safe_table, math = safe_math, utf8 = safe_utf8,
    lush = {theme = safe_theme},
}
environment._G = environment

-- Defense in depth: remove unsafe base globals in the dedicated VM as well.
-- These changes never touch the shell's Lua state.
for _, name in ipairs{"_G", "_lush", "load", "loadfile", "dofile", "require", "collectgarbage",
    "pcall", "xpcall", "coroutine", "getmetatable", "setmetatable", "rawset", "print", "warn",
    "os", "io", "package", "debug"} do host_globals[name] = nil end
original_theme.load = nil

local function prompt(value)
    if lua_type(value) ~= "table" or lua_rawget(value, "kind") ~= "prompt" then
        fail("theme must return a prompt descriptor or builder function")
    end
    return data(value)
end
return function(source, filename)
    local chunk, problem = lua_load(source, filename, "t", environment)
    if not chunk then lua_error(problem, 0) end
    local value = chunk()
    if lua_type(value) == "function" then
        return function(context, options)
            return prompt(value(data(context), data(options)))
        end
    end
    return prompt(value)
end
