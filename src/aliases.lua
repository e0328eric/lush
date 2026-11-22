-- Aliases are ordinary Lua globals. Registration never calls an alias or
-- resolves an executable; argv aliases construct a fresh lazy command plan.
local globals, namespace = _G, lush
local lua_type, lua_next, lua_rawget, lua_rawset = type, next, rawget, rawset
local lua_error, lua_rawequal = error, rawequal
local pack, unpack, sort = table.pack, table.unpack, table.sort
local match, find, number_type = string.match, string.find, math.type
local command_namespace = cmd
local command_call = getmetatable(command_namespace).__call
local registry = {}
local keywords = {}
for word in
    (
        "and break do else elseif end false for function global goto if in local nil not or "
        .. "repeat return then true until while"
    ):gmatch("%S+")
do
    keywords[word] = true
end

local function fail(message)
    lua_error("alias: " .. message, 3)
end
local function name_argument(name)
    if
        lua_type(name) ~= "string"
        or not match(name, "^[A-Za-z_][A-Za-z_0-9]*$")
        or keywords[name]
    then
        fail("name must be a Lua identifier other than a keyword")
    end
    if name == "_G" or name == "lush" then
        fail("cannot replace " .. name)
    end
    return name
end
local function copy_command(command)
    local copied = {}
    for index = 1, #command do
        copied[index] = command[index]
    end
    return copied
end
local function command_argument(value)
    local count, highest = 0, 0
    -- Raw traversal ignores __pairs, __index, __len and __call. Only stored
    -- array entries are copied; no reference to the supplied table survives.
    for key in lua_next, value do
        if number_type(key) ~= "integer" or key < 1 then
            fail("command must be a dense argv array")
        end
        count = count + 1
        if key > highest then
            highest = key
        end
    end
    if count == 0 then
        fail("command must be a nonempty argv array")
    end
    if highest ~= count then
        fail("command must be a dense argv array")
    end
    local command = {}
    for index = 1, count do
        local argument = lua_rawget(value, index)
        if lua_type(argument) == "number" then
            -- Primitive concatenation uses Lua's numeric conversion without
            -- consulting a user-installed number __tostring metamethod.
            argument = "" .. argument
        end
        if lua_type(argument) ~= "string" or find(argument, "\0", 1, true) then
            fail("command argument " .. index .. " must be a string or number without NUL")
        end
        command[index] = argument
    end
    if command[1] == "" then
        fail("executable must not be empty")
    end
    return command
end
local function prepare(name, value)
    name_argument(name)
    local kind = lua_type(value)
    if kind == "function" then
        return { name = name, kind = "function", callable = value }
    end
    if kind ~= "table" then
        fail("value must be a function or dense argv array")
    end
    local command = command_argument(value)
    local function callable(...)
        local extra, arguments = pack(...), copy_command(command)
        local fixed = #command
        for index = 1, extra.n do
            arguments[fixed + index] = extra[index]
        end
        return command_call(command_namespace, unpack(arguments, 1, fixed + extra.n))
    end
    return { name = name, kind = "external", callable = callable, command = command }
end

local function register(name, value)
    local entries = {}
    if lua_type(name) == "table" then
        if value ~= nil then
            fail("bulk registration accepts one table")
        end
        for key, target in lua_next, name do
            entries[#entries + 1] = prepare(key, target)
        end
        sort(entries, function(left, right)
            return left.name < right.name
        end)
    else
        entries[1] = prepare(name, value)
    end
    -- Nothing is exported until every entry has passed validation.
    for index = 1, #entries do
        local entry = entries[index]
        lua_rawset(globals, entry.name, entry.callable)
        registry[entry.name] = entry
    end
    return nil
end
local function snapshot()
    local rows = {}
    for name, entry in lua_next, registry do
        if lua_rawequal(lua_rawget(globals, name), entry.callable) then
            local row = { name = name, kind = entry.kind }
            if entry.command then
                row.command = copy_command(entry.command)
            end
            rows[#rows + 1] = row
        end
    end
    sort(rows, function(left, right)
        return left.name < right.name
    end)
    return rows
end

namespace.alias, namespace.aliases = register, snapshot
globals.alias, globals.aliases = register, snapshot
