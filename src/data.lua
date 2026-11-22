-- Structured-data transforms. Methods construct ordinary Lush Flows; their
-- global counterparts construct stages for Lua's existing | operator.
local Flow, Exec = assert(lush.Flow), assert(lush.Exec)
local make_stage, stream, capture = assert(lush.stage), assert(lush.stream), assert(lush.capture)
local null, json = assert(lush.null), assert(lush.json)
local object_tag, array_tag = getmetatable(json.object()), getmetatable(json.array())
local argument_count = select

local function fail(name, message)
    error(name .. ": " .. message, 3)
end
local function field(value, name)
    if type(value) ~= "string" then
        fail(name, "field must be a string")
    end
    return value
end
local function callback(value, name)
    if type(value) ~= "function" then
        fail(name, "requires a Lua function")
    end
    return value
end
local function integer(value, name, nonnegative)
    local result = type(value) == "number" and math.tointeger(value)
    if not result or (nonnegative and result < 0) then
        fail(
            name,
            nonnegative and "count must be a nonnegative integer" or "start must be an integer"
        )
    end
    return result
end
local function delayed(resolve)
    return setmetatable({ resolve = resolve }, Flow)
end
local function as_flow(value)
    if getmetatable(value) == Exec then
        return delayed(function()
            return { capture(value):check().stdout }
        end)
    end
    return stream(value)
end
local function record(value, name)
    if
        type(value) ~= "table"
        or rawequal(value, null)
        or rawequal(getmetatable(value), array_tag)
    then
        fail(name, "requires records with string field names")
    end
    for key in next, value do
        if type(key) ~= "string" then
            fail(name, "requires records with string field names")
        end
    end
    return value
end
local function copy_record(value, name)
    record(value, name)
    local result = json.object()
    for key, item in next, value do
        result[key] = item
    end
    return result
end
local function is_array(value)
    if
        type(value) ~= "table"
        or rawequal(value, null)
        or rawequal(getmetatable(value), object_tag)
    then
        return false
    end
    local count = #value
    for index = 1, count do
        if rawget(value, index) == nil then
            return false
        end
    end
    for key in next, value do
        if math.type(key) ~= "integer" or key < 1 or key > count then
            return false
        end
    end
    return true
end

-- Structural comparison keeps record/list uniqueness useful while retaining
-- Lua equality for scalars, functions, userdata and table keys. No __eq runs.
local function same(left, right, visited)
    if rawequal(left, right) then
        return true
    end
    if type(left) ~= type(right) then
        return false
    end
    if type(left) ~= "table" or rawequal(left, null) or rawequal(right, null) then
        return false
    end
    if is_array(left) ~= is_array(right) then
        return false
    end
    local matches = visited[left]
    if matches and matches[right] then
        return true
    end
    if not matches then
        matches = {}
        visited[left] = matches
    end
    matches[right] = true
    for key, value in next, left do
        local other = rawget(right, key)
        if other == nil or not same(value, other, visited) then
            return false
        end
    end
    for key in next, right do
        if rawget(left, key) == nil then
            return false
        end
    end
    return true
end

function Flow:reverse()
    return delayed(function()
        local values, result = self:collect(), {}
        for index = #values, 1, -1 do
            result[#result + 1] = values[index]
        end
        return result
    end)
end
function Flow:uniq(key)
    if key ~= nil then
        field(key, "uniq")
    end
    return delayed(function()
        local result, scalars, tables = {}, {}, {}
        for _, item in ipairs(self:collect()) do
            local value = item
            if key ~= nil then
                record(item, "uniq")
                value = rawget(item, key)
                if value == nil then
                    value = null
                end
            end
            local duplicate = false
            if type(value) == "table" and not rawequal(value, null) then
                for _, previous in ipairs(tables) do
                    if same(value, previous, {}) then
                        duplicate = true
                        break
                    end
                end
                if not duplicate then
                    tables[#tables + 1] = value
                end
            elseif type(value) == "number" and value ~= value then
                -- NaN never compares equal, including to another NaN.
            else
                duplicate = scalars[value] == true
                scalars[value] = true
            end
            if not duplicate then
                result[#result + 1] = item
            end
        end
        return result
    end)
end
function Flow:first(count)
    count = integer(count == nil and 1 or count, "first", true)
    return delayed(function()
        local values, result = self:collect(), {}
        for index = 1, math.min(count, #values) do
            result[index] = values[index]
        end
        return result
    end)
end
function Flow:last(count)
    count = integer(count == nil and 1 or count, "last", true)
    return delayed(function()
        local values, result = self:collect(), {}
        for index = math.max(1, #values - count + 1), #values do
            result[#result + 1] = values[index]
        end
        return result
    end)
end
function Flow:enumerate(start)
    start = integer(start == nil and 0 or start, "enumerate", false)
    return delayed(function()
        local values, result = self:collect(), {}
        if #values > 0 and start > math.maxinteger - (#values - 1) then
            fail("enumerate", "index overflow")
        end
        for index, item in ipairs(values) do
            result[index] = { index = start + index - 1, item = item }
        end
        return result
    end)
end
function Flow:flatten()
    return delayed(function()
        local result = {}
        for _, item in ipairs(self:collect()) do
            if is_array(item) then
                for _, nested in ipairs(item) do
                    result[#result + 1] = nested
                end
            else
                result[#result + 1] = item
            end
        end
        return result
    end)
end
local function extra_values(name, ...)
    if argument_count("#", ...) ~= 1 then
        fail(name, "requires exactly one value or list")
    end
    local value = ...
    if value == nil then
        fail(name, "requires a value; use json.null for null")
    end
    return as_flow(value)
end
function Flow:append(...)
    local additional = extra_values("append", ...)
    return delayed(function()
        local result = {}
        for _, item in ipairs(self:collect()) do
            result[#result + 1] = item
        end
        for _, item in ipairs(additional:collect()) do
            result[#result + 1] = item
        end
        return result
    end)
end
function Flow:prepend(...)
    local additional = extra_values("prepend", ...)
    return delayed(function()
        local result = {}
        for _, item in ipairs(additional:collect()) do
            result[#result + 1] = item
        end
        for _, item in ipairs(self:collect()) do
            result[#result + 1] = item
        end
        return result
    end)
end
function Flow:columns()
    return delayed(function()
        local seen, result = {}, {}
        for _, item in ipairs(self:collect()) do
            record(item, "columns")
            for key in next, item do
                if not seen[key] then
                    seen[key] = true
                    result[#result + 1] = key
                end
            end
        end
        table.sort(result)
        return result
    end)
end
local function fields(name, ...)
    local count, result = argument_count("#", ...), {}
    if count == 0 then
        fail(name, "requires at least one field")
    end
    for index = 1, count do
        result[index] = field(argument_count(index, ...), name)
    end
    return result
end
function Flow:reject(...)
    local names = fields("reject", ...)
    return delayed(function()
        local result = {}
        for index, item in ipairs(self:collect()) do
            local row = copy_record(item, "reject")
            for _, key in ipairs(names) do
                row[key] = nil
            end
            result[index] = row
        end
        return result
    end)
end
function Flow:rename(old_name, new_name)
    field(old_name, "rename")
    field(new_name, "rename")
    return delayed(function()
        local result = {}
        for index, item in ipairs(self:collect()) do
            local row = copy_record(item, "rename")
            if old_name ~= new_name and rawget(item, old_name) ~= nil then
                if rawget(item, new_name) ~= nil then
                    fail("rename", "destination field already exists: " .. new_name)
                end
                row[new_name], row[old_name] = row[old_name], nil
            end
            result[index] = row
        end
        return result
    end)
end
function Flow:update(key, transform)
    field(key, "update")
    callback(transform, "update")
    return delayed(function()
        local result = {}
        for index, item in ipairs(self:collect()) do
            local row = copy_record(item, "update")
            local previous = rawget(item, key)
            if previous == nil then
                previous = null
            end
            local value = transform(previous, index)
            row[key] = value == nil and null or value
            result[index] = row
        end
        return result
    end)
end
function Flow:default(key, ...)
    field(key, "default")
    if argument_count("#", ...) ~= 1 then
        fail("default", "requires an explicit replacement value")
    end
    local replacement = ...
    if replacement == nil then
        replacement = null
    end
    return delayed(function()
        local result = {}
        for index, item in ipairs(self:collect()) do
            local row = copy_record(item, "default")
            if rawget(row, key) == nil or rawequal(rawget(row, key), null) then
                row[key] = replacement
            end
            result[index] = row
        end
        return result
    end)
end
function Flow:any(predicate)
    callback(predicate, "any")
    for index, item in ipairs(self:collect()) do
        if predicate(item, index) then
            return true
        end
    end
    return false
end
function Flow:all(predicate)
    callback(predicate, "all")
    for index, item in ipairs(self:collect()) do
        if not predicate(item, index) then
            return false
        end
    end
    return true
end
function Flow:reduce(transform, ...)
    callback(transform, "reduce")
    if argument_count("#", ...) ~= 1 then
        fail("reduce", "requires an explicit initial value")
    end
    local accumulator = ...
    for index, item in ipairs(self:collect()) do
        accumulator = transform(accumulator, item, index)
    end
    return accumulator
end

-- Validate when a factory is called, while deferring stream evaluation until
-- the resulting stage receives its input.
local exports = {}
local function method_stage(name, ...)
    local args = { n = argument_count("#", ...), ... }
    -- Constructing a method against an empty flow validates all arguments;
    -- scalar reductions on that empty flow do not invoke their callback.
    Flow[name](stream({}), table.unpack(args, 1, args.n))
    return make_stage(function(value)
        return Flow[name](as_flow(value), table.unpack(args, 1, args.n))
    end)
end
for _, name in ipairs({
    "reverse",
    "uniq",
    "first",
    "last",
    "enumerate",
    "flatten",
    "append",
    "prepend",
    "columns",
    "reject",
    "rename",
    "update",
    "default",
    "any",
    "all",
    "reduce",
}) do
    exports[name] = function(...)
        return method_stage(name, ...)
    end
end
for name, value in pairs(exports) do
    _G[name], lush[name] = value, value
end
lush.data = exports
