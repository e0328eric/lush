-- Literal filesystem operations; all OS work uses Glosso's native std library.
local native = assert(_lush)
local lua_type, lua_error, lua_pairs = type, error, pairs
local function fail(message) lua_error(message, 3) end
local function text(value, name)
    if lua_type(value) ~= "string" or value:find("\0", 1, true) then
        fail((name or "path") .. " must be a string without NUL")
    end
    return value
end
local function checked(value, message)
    if value == nil then fail(message or "filesystem operation failed") end
    return value
end
local function options(value, allowed, name)
    if value == nil then return {} end
    if lua_type(value) ~= "table" then fail(name .. " options must be a table") end
    for key, entry in lua_pairs(value) do
        if not allowed[key] then fail(name .. ": unknown option " .. tostring(key)) end
        if lua_type(entry) ~= "boolean" then fail(name .. "." .. key .. " must be a boolean") end
    end
    return value
end

function mkdir(value, opts)
    opts = options(opts, {parents = true}, "mkdir")
    return checked(native.mkdir(text(value), opts.parents ~= false))
end
function touch(value) return checked(native.touch(text(value))) end
function cp(source, destination, opts)
    opts = options(opts, {recursive = true, overwrite = true}, "cp")
    return checked(native.cp(text(source, "source"), text(destination, "destination"),
                             opts.recursive == true, opts.overwrite == true))
end
function mv(source, destination, opts)
    opts = options(opts, {overwrite = true}, "mv")
    return checked(native.mv(text(source, "source"), text(destination, "destination"), opts.overwrite == true))
end
function rm(value, opts)
    opts = options(opts, {recursive = true, force = true}, "rm")
    return checked(native.rm(text(value), opts.recursive == true, opts.force == true))
end
function stat(value, follow)
    if follow ~= nil and lua_type(follow) ~= "boolean" then fail("stat follow must be a boolean") end
    return checked(native.stat(text(value), follow ~= false))
end
function exists(value) return checked(native.exists(text(value))) end

path = {}
function path.join(...)
    return checked(native.path("join", ...))
end
for _, operation in ipairs({"dirname", "basename", "stem", "extension", "expand", "normalize"}) do
    path[operation] = function(value) return checked(native.path(operation, text(value))) end
end
path.exists = exists
lush.mkdir, lush.touch, lush.cp, lush.mv, lush.rm = mkdir, touch, cp, mv, rm
lush.stat, lush.exists, lush.path = stat, exists, path
