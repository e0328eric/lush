-- Shell conveniences that retain ordinary Lua calling and scoping rules.
local native = assert(_lush)
local type, select = type, select
local function text(value, name)
    assert(type(value) == "string" and not value:find("\0", 1, true),
           (name or "argument") .. " must be a string without NUL")
    return value
end
function source(filename, ...)
    text(filename, "source path")
    local contents = lush.read(filename)
    if contents:sub(1, 3) == "\239\187\191" then contents = contents:sub(4) end
    if contents:sub(1, 2) == "#!" then contents = contents:match("\n.*") or "" end
    return assert(load(contents, "@" .. filename, "t", _G))(...)
end
function which(name)
    text(name, "executable name")
    assert(#name > 0, "executable name must not be empty")
    return native.which(native.path_arg(name))
end
function describe(value)
    if value == json.null then return "null" end
    local meta = getmetatable(value)
    if meta == lush.Flow then return "stream" end
    if meta == lush.Exec then return "command" end
    if meta == lush.Result then return "result" end
    if type(value) ~= "table" then return math.type(value) or type(value) end
    -- JSON explicitly tagged objects and arrays retain their identities.
    if meta == getmetatable(json.object()) then return "record" end
    if meta == getmetatable(json.array()) then return "list" end
    local count = #value
    for i = 1, count do if rawget(value, i) == nil then return "record" end end
    for key in pairs(value) do
        if math.type(key) ~= "integer" or key < 1 or key > count then return "record" end
    end
    return "list"
end
function version()
    return {name = "lush", version = "0.1.0", lua = _VERSION, platform = native.platform}
end
function clear() assert(native.clear()); end
function printf(format, ...)
    text(format, "printf format")
    io.write(string.format(format, ...))
end
function contains(values, item)
    if getmetatable(values) == lush.Flow then values = values:collect() end
    assert(describe(values) == "list", "contains requires a list or stream")
    for _, value in ipairs(values) do if value == item then return true end end
    return false
end
for _, name in ipairs({"source", "which", "describe", "version", "clear", "printf", "contains"}) do
    lush[name] = _G[name]
end
