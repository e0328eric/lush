-- Completion inspects Lua tokens and native directory/PATH snapshots. It never
-- evaluates the input, indexes a metatable, or calls a user-provided function.
local native = assert(_lush)
local assert, error, ipairs, next, pairs, pcall, rawequal, rawget, tonumber, tostring, type =
    assert, error, ipairs, next, pairs, pcall, rawequal, rawget, tonumber, tostring, type
local math, string, table = math, string, table
local documented_help, registered_aliases = lush.help, lush.aliases
local keywords = {}
for word in ("and break do else elseif end false for function global goto if in local nil not or " ..
             "repeat return then true until while"):gmatch("%S+") do keywords[word] = true end

local function identifier(value)
    return value:match("^[A-Za-z_][A-Za-z_0-9]*$") ~= nil and not keywords[value]
end
local function quoted(value, quote)
    quote = quote or '"'
    return (value:gsub('[%z\1-\31\\' .. quote .. ']', function(c)
        if c == "\\" then return "\\\\" end
        if c == quote then return "\\" .. quote end
        if c == "\n" then return "\\n" end
        if c == "\r" then return "\\r" end
        if c == "\t" then return "\\t" end
        return string.format("\\%03d", c:byte())
    end))
end
local function decoded(value)
    local out, i = {}, 1
    local simple = {a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v",
                    ["\\"] = "\\", ['"'] = '"', ["'"] = "'"}
    while i <= #value do
        local c = value:sub(i, i)
        if c ~= "\\" then out[#out + 1] = c; i = i + 1
        else
            local next_char = value:sub(i + 1, i + 1)
            if simple[next_char] then out[#out + 1] = simple[next_char]; i = i + 2
            elseif next_char == "z" then
                i = i + 2
                while value:sub(i, i):match("%s") do i = i + 1 end
            elseif next_char == "\n" or next_char == "\r" then
                out[#out + 1] = "\n"; i = i + 2
                if next_char == "\r" and value:sub(i, i) == "\n" then i = i + 1 end
            elseif next_char == "x" and value:sub(i + 2, i + 3):match("^%x%x$") then
                out[#out + 1] = string.char(tonumber(value:sub(i + 2, i + 3), 16)); i = i + 4
            elseif next_char == "u" then
                local digits = value:sub(i + 2):match("^%{(%x+)%}")
                local ok, rune = false, nil
                if digits then ok, rune = pcall(utf8.char, tonumber(digits, 16)) end
                if ok then out[#out + 1] = rune; i = i + #digits + 4
                else out[#out + 1] = "\\"; i = i + 1 end
            elseif next_char:match("%d") then
                local digits = value:sub(i + 1):match("^%d%d?%d?")
                local number = tonumber(digits)
                if number <= 255 then out[#out + 1] = string.char(number); i = i + #digits + 1
                else out[#out + 1] = "\\"; i = i + 1 end
            else
                -- An unfinished Windows path may contain a not-yet-valid Lua
                -- escape. Treat it as a literal slash, then emit valid quoting.
                out[#out + 1] = "\\"; i = i + 1
            end
        end
    end
    return table.concat(out)
end
local function long_open(source, at)
    local equals = source:sub(at):match("^%[(=*)%[")
    if equals ~= nil then return equals, at + #equals + 2 end
end
local function lex(source)
    local tokens, i, length = {}, 1, #source
    local function token(kind, first, last)
        tokens[#tokens + 1] = {kind = kind, first = first, last = last,
                               value = source:sub(first, last)}
    end
    while i <= length do
        local c, first = source:sub(i, i), i
        if c:match("%s") then i = i + 1
        elseif source:sub(i, i + 1) == "--" then
            local equals, body = long_open(source, i + 2)
            if equals then
                local _, finish = source:find("]" .. equals .. "]", body, true)
                if not finish then return tokens, {kind = "comment"} end
                i = finish + 1
            else
                local finish = source:find("\n", i + 2, true)
                if not finish then return tokens, {kind = "comment"} end
                i = finish + 1
            end
        elseif c == '"' or c == "'" then
            i = i + 1
            while i <= length do
                local current = source:sub(i, i)
                if current == "\\" then
                    local escaped = source:sub(i + 1, i + 1)
                    i = i + 2
                    if escaped == "z" then
                        while source:sub(i, i):match("%s") do i = i + 1 end
                    elseif escaped == "\r" and source:sub(i, i) == "\n" then i = i + 1 end
                elseif current == c then break
                elseif current == "\n" or current == "\r" then
                    -- A bare newline ends an invalid short literal; no path
                    -- completion should silently repair unrelated source.
                    return tokens, {kind = "invalid"}
                else i = i + 1 end
            end
            if i > length then
                return tokens, {kind = "string", first = first, quote = c,
                                value = decoded(source:sub(first + 1))}
            end
            token("string", first, i); i = i + 1
        else
            local equals, body = long_open(source, i)
            if equals then
                local _, finish = source:find("]" .. equals .. "]", body, true)
                if not finish then return tokens, {kind = "long-string"} end
                token("long-string", first, finish); i = finish + 1
            elseif c:match("[A-Za-z_]") then
                i = i + 1
                while source:sub(i, i):match("[A-Za-z_0-9]") do i = i + 1 end
                token("name", first, i - 1)
            elseif c:match("%d") then
                i = i + 1
                while source:sub(i, i):match("[A-Za-z_0-9%.]") do i = i + 1 end
                token("number", first, i - 1)
            else token("symbol", i, i); i = i + 1 end
        end
    end
    return tokens
end

-- Resolve only explicitly stored global/table values. rawget prevents a
-- completion from triggering __index or an executable namespace's lazy lookup.
local function receiver(tokens, last)
    if not tokens[last] or tokens[last].kind ~= "name" then return nil end
    local first = last
    while first > 2 and tokens[first - 1].value == "." and tokens[first - 2].kind == "name" do
        first = first - 2
    end
    local value = rawget(_G, tokens[first].value)
    for i = first + 2, last, 2 do
        if type(value) ~= "table" then return nil, first end
        value = rawget(value, tokens[i].value)
    end
    return value, first
end
local function executable_names(prefix)
    if type(native.executables) ~= "function" then return {} end
    local ok, values = pcall(native.executables, prefix)
    if not ok or type(values) ~= "table" then return {} end
    local result = {}
    for _, name in ipairs(values) do
        if type(name) == "string" then
            local compared, fragment = name, prefix
            if native.platform == "windows" then compared, fragment = name:lower(), prefix:lower() end
            if compared:sub(1, #fragment) == fragment then result[#result + 1] = name end
        end
    end
    table.sort(result)
    return result
end
local function starts_with(value, prefix)
    if native.platform == "windows" then value, prefix = value:lower(), prefix:lower() end
    return value:sub(1, #prefix) == prefix
end
local function file_candidates(prefix, directories_only, executables_only)
    local separator
    for i = #prefix, 1, -1 do
        local c = prefix:sub(i, i)
        if c == "/" or (native.platform == "windows" and c == "\\") then separator = i; break end
    end
    local directory = separator and prefix:sub(1, separator) or ""
    local fragment = separator and prefix:sub(separator + 1) or prefix
    local query = directory ~= "" and directory or "."
    local ok, entries = pcall(native.list, query, true)
    if not ok or type(entries) ~= "table" then return {} end
    local result = {}
    for _, entry in ipairs(entries) do
        local name, kind = entry.name, entry.type or entry.kind
        local is_directory = entry.is_directory == true or kind == "dir" or kind == "directory"
        if type(name) == "string" and name ~= "." and name ~= ".." and starts_with(name, fragment) and
            (not directories_only or is_directory) and
            (not executables_only or is_directory or entry.executable) then
            result[#result + 1] = {value = directory .. name .. (is_directory and "/" or ""),
                                  label = name .. (is_directory and "/" or "")}
        end
    end
    table.sort(result, function(a, b) return a.value < b.value end)
    return result
end
local function string_context(tokens)
    local previous = tokens[#tokens]
    if not previous then return false, false end
    local index = #tokens
    if previous.value == "(" or previous.value == "[" or previous.value == "{" then index = index - 1 end
    local value = receiver(tokens, index)
    local executable = value == rawget(_G, "cmd") or value == rawget(_G, "run") or value == rawget(_G, "capture")
    local directories = value == rawget(_G, "cd")
    return executable, directories
end
local function result_set(start)
    local result = {labels = {}, replace_start = start}
    local seen = {}
    return result, function(replacement, label)
        if seen[replacement] then return end
        seen[replacement] = true
        result[#result + 1] = replacement
        result.labels[#result.labels + 1] = label or replacement
    end
end

-- Bounded nominal schema analysis. It recognizes fixed producers and simple
-- lexical bindings; it never evaluates Lua, calls a producer, or probes native
-- state. Unknown/data-dependent transformations deliberately erase item hints.
local schema_callbacks = {where = true, filter = true, map = true, each = true, foreach = true,
    any = true, all = true, sort_by = true}
local schema_preserving = {where = true, filter = true, take = true, skip = true, sort_by = true,
    reverse = true, uniq = true, first = true, last = true}
local function metadata()
    local schemas = rawget(lush, "schemas")
    return type(schemas) == "table" and schemas or {}
end
local function raw_path(name)
    local value, first = _G, true
    for part in name:gmatch("[^.]+") do
        if type(value) ~= "table" then return nil end
        value = rawget(value, part)
        if value == nil and first then value = rawget(lush, part) end
        first = false
    end
    return value
end
local initial_producers = {help = rawget(_G, "help"), cmd = rawget(_G, "cmd")}
for name in next, rawget(metadata(), "producers") or {} do initial_producers[name] = raw_path(name) end
local function declared(name)
    local producers = rawget(metadata(), "producers")
    return type(producers) == "table" and rawget(producers, name) or nil
end
local function member(schema, name)
    local fields = type(schema) == "table" and rawget(schema, "fields")
    if type(fields) ~= "table" then return nil end
    for index = 1, math.min(rawlen(fields), 64) do
        local field = rawget(fields, index)
        if type(field) == "table" and rawget(field, "name") == name then return field end
    end
end
local function enumerate_schema(input)
    local fields, template = {}, rawget(metadata(), "enumerated")
    if type(template) ~= "table" then return nil end
    for index = 1, math.min(rawlen(template), 64) do
        local original = rawget(template, index)
        if type(original) == "table" then
            local copied = {}
            for key, value in next, original do copied[key] = value end
            if rawget(original, "name") == "item" and type(input) == "table" then
                copied.type, copied.fields, copied.items = rawget(input, "type"), rawget(input, "fields"), rawget(input, "items")
                copied.data_dependent = rawget(input, "data_dependent")
            end
            fields[index] = copied
        end
    end
    return {type = "stream", items = {type = "record", fields = fields}}
end
local function lexical_context(tokens)
    if #tokens > 4096 then return nil end
    local scopes, matching, opens = {{kind = "root", bindings = {}}}, {}, {}
    local blocks, block_ends, scheduled = {}, {}, {}
    local closing = {["("] = ")", ["["] = "]", ["{"] = "}"}
    for index, token in ipairs(tokens) do
        if token.kind == "symbol" then
            if closing[token.value] then opens[#opens + 1] = index
            elseif token.value == ")" or token.value == "]" or token.value == "}" then
                local first = opens[#opens]
                if first and closing[tokens[first].value] == token.value then
                    matching[index], matching[first] = first, index; opens[#opens] = nil
                else opens = {} end
            end
        end
        if token.kind == "name" then
            local value = token.value
            if value == "function" or value == "if" or value == "for" or value == "while" or value == "repeat" then
                blocks[#blocks + 1] = {first = index, await_do = value == "for" or value == "while"}
            elseif value == "do" then
                if blocks[#blocks] and blocks[#blocks].await_do then blocks[#blocks].await_do = false
                else blocks[#blocks + 1] = {first = index} end
            elseif value == "end" or value == "until" then
                local block = blocks[#blocks]
                if block then block_ends[block.first] = index; blocks[#blocks] = nil end
            end
        end
    end
    local function lookup(name)
        for index = #scopes, 1, -1 do
            local value = rawget(scopes[index].bindings, name)
            if value ~= nil then return value, true end
        end
        return nil, false
    end
    local function callee(index)
        if not tokens[index] or tokens[index].kind ~= "name" then return nil end
        local first, names = index, {}
        while first > 2 and tokens[first - 1].value == "." and tokens[first - 2].kind == "name" do first = first - 2 end
        if tokens[first - 1] and (tokens[first - 1].value == "." or tokens[first - 1].value == ":") then return nil end
        local _, bound = lookup(tokens[first].value)
        if bound then return nil, first end
        for at = first, index, 2 do names[#names + 1] = tokens[at].value end
        local qualified = table.concat(names, ".")
        return qualified, first, raw_path(qualified)
    end
    local function fixed(qualified, actual)
        local name = declared(qualified) and qualified or qualified:gsub("^lush%.", "")
        local schema = declared(name)
        if schema and actual ~= nil and actual == initial_producers[name] then return schema, name end
    end
    local infer
    local function transformed(input, method)
        if type(input) ~= "table" then return nil end
        local input_type = rawget(input, "type")
        if input_type == "stream" then
            if schema_preserving[method] then return input end
            if method == "enumerate" then return enumerate_schema(rawget(input, "items")) end
            if method == "collect" then return {type = "array", items = rawget(input, "items")} end
        end
        local fields = rawget(input, "fields")
        local schemas = metadata()
        if fields and fields == rawget(schemas, "exec") then return declared("Exec." .. method) end
        if fields and fields == rawget(schemas, "result") then
            if method == "check" then return input end
            return declared("Result." .. method)
        end
        return nil
    end
    local function command_builder(last)
        if not tokens[last] then return false end
        local receiver_end
        if tokens[last].kind == "name" and tokens[last - 1] and tokens[last - 1].value == "." then receiver_end = last - 2
        elseif tokens[last].value == "]" and matching[last] then receiver_end = matching[last] - 1 end
        if receiver_end then
            local name, first, actual = callee(receiver_end)
            if (name == "cmd" or name == "lush.cmd") and actual == initial_producers.cmd then
                return true, first
            end
        end
        return false
    end
    local function stream_literal(first, last, depth)
        if not tokens[first] or tokens[first].value ~= "{" or matching[first] ~= last then return nil end
        local finish = last - 1
        if tokens[finish] and tokens[finish].value == "," then finish = finish - 1 end
        local item, start = infer(finish, depth + 1)
        if start == first + 1 and item then return {type = "stream", items = item} end
    end
    infer = function(index, depth)
        depth = depth or 0
        if depth > 20 or not tokens[index] then return nil end
        local token = tokens[index]
        if token.kind == "name" then
            if tokens[index - 1] and tokens[index - 1].value == "." then
                local base, first = infer(index - 2, depth + 1)
                return member(base, token.value), first
            end
            local value = lookup(token.value)
            return value ~= false and value or nil, index
        end
        if token.value == "]" and matching[index] then
            local opening = matching[index]
            local base, first = infer(opening - 1, depth + 1)
            local key = tokens[opening + 1]
            if key and opening + 2 == index then
                if key.kind == "string" then return member(base, decoded(key.value:sub(2, -2))), first end
                if key.kind == "number" and type(base) == "table" then return rawget(base, "items"), first end
            end
            return nil, first
        end
        if token.value == "}" and matching[index] then
            local opening = matching[index]
            local name, first, actual = callee(opening - 1)
            if name and (name == "stream" or name == "lush.stream") and actual == initial_producers.stream then
                return stream_literal(opening, index, depth), first
            end
            if name then
                local schema = fixed(name, actual)
                return schema and not rawget(schema, "data_dependent") and schema or nil, first
            end
            return nil, opening
        end
        if token.value ~= ")" or not matching[index] then return nil, index end
        local opening, called = matching[index], matching[index] - 1
        if tokens[called] and tokens[called].kind == "name" and tokens[called - 1] and tokens[called - 1].value == ":" then
            local input, first = infer(called - 2, depth + 1)
            return transformed(input, tokens[called].value), first
        end
        local is_command, command_first = command_builder(called)
        if is_command then
            local first = command_first
            return declared("cmd"), first
        end
        local name, first, actual = callee(called)
        if name then
            if tokens[first - 1] and tokens[first - 1].value == "|" then
                local input, start = infer(first - 2, depth + 1)
                return transformed(input, name:gsub("^lush%.", "")), start
            end
            local canonical = name:gsub("^lush%.", "")
            if canonical == "help" and actual == initial_producers.help then
                local argument = tokens[opening + 1]
                if argument and argument.kind == "string" then
                    return declared("help." .. decoded(argument.value:sub(2, -2))), first
                end
                return nil, first
            end
            if canonical == "stream" and actual == initial_producers.stream then
                local item_first, item_last = opening + 1, index - 1
                if tokens[item_first] and tokens[item_first].value == "{" then
                    return stream_literal(item_first, item_last, depth), first
                end
            end
            local schema = fixed(name, actual)
            return schema and not rawget(schema, "data_dependent") and schema or nil, first
        end
        -- Parenthesized expressions are transparent, but a call's argument
        -- parentheses must not turn unknown_function(stat(...)) into a record.
        local previous = tokens[opening - 1]
        if not previous or previous.kind ~= "name" and previous.value ~= ")" and previous.value ~= "]" then
            local result, first = infer(index - 1, depth + 1)
            if first == opening + 1 then return result, opening end
        end
        return nil, opening
    end
    local function callback_input(index)
        if not tokens[index - 1] or tokens[index - 1].value ~= "(" then return nil end
        local called = index - 2
        if not tokens[called] or not schema_callbacks[tokens[called].value] then return nil end
        local input
        if tokens[called - 1] and tokens[called - 1].value == ":" then input = infer(called - 2)
        else
            local name, first = callee(called)
            if name and tokens[first - 1] and tokens[first - 1].value == "|" then input = infer(first - 2) end
        end
        return type(input) == "table" and rawget(input, "type") == "stream" and rawget(input, "items") or nil
    end
    local function assign(name, value, local_binding)
        if not local_binding then
            for index = #scopes, 1, -1 do
                if rawget(scopes[index].bindings, name) ~= nil then
                    -- A conditional or deferred function body cannot establish
                    -- the value that an enclosing scope will later observe.
                    for nested = index + 1, #scopes do
                        local kind = scopes[nested].kind
                        if kind == "function" or kind == "if" or kind == "for" or kind == "while" or kind == "repeat" then value = nil; break end
                    end
                    scopes[index].bindings[name] = value or false
                    return
                end
            end
        end
        scopes[#scopes].bindings[name] = value or false
    end
    local function initializer(first)
        -- Consume only the boundaries of an initializer, without interpreting
        -- its operators. Unknown values still replace an earlier schema, but
        -- the new local is not visible inside its own initializer.
        local function prefix_end(at, depth)
            if depth > 20 or not tokens[at] then return nil end
            local value, token = tokens[at].value, tokens[at]
            local last = at
            if value == "not" or value == "-" or value == "#" or value == "~" then
                return prefix_end(at + 1, depth + 1)
            elseif value == "function" then last = block_ends[at]
            elseif value == "{" or value == "(" then last = matching[at]
            elseif token.kind ~= "name" and token.kind ~= "number" and token.kind ~= "string" and token.kind ~= "long-string" then return nil end
            if not last then return nil end
            while tokens[last + 1] do
                local next_value = tokens[last + 1].value
                if next_value == "(" or next_value == "[" or next_value == "{" then
                    if not matching[last + 1] then return nil end
                    last = matching[last + 1]
                elseif next_value == ":" and tokens[last + 2] and tokens[last + 3] and tokens[last + 3].value == "(" then
                    if not matching[last + 3] then return nil end
                    last = matching[last + 3]
                elseif next_value == "." and tokens[last + 2] and tokens[last + 2].value == "." then break
                elseif next_value == "." then
                    if not tokens[last + 2] or tokens[last + 2].kind ~= "name" then return nil end
                    last = last + 2
                elseif tokens[last + 1].kind == "string" or tokens[last + 1].kind == "long-string" then last = last + 1
                else break end
            end
            return last
        end
        local last = prefix_end(first, 0)
        if not last then return nil, false end
        while tokens[last + 1] do
            local value = tokens[last + 1].value
            local width = 0
            if value == "and" or value == "or" or value:match("^[+*/%%^&|<>~-]$") then width = 1 end
            if (value == "." or value == "=" or value == "~" or value == "/" or value == "<" or value == ">") and tokens[last + 2] then
                local pair = value .. tokens[last + 2].value
                if pair == ".." or pair == "==" or pair == "~=" or pair == "//" or pair == "<<" or pair == ">>" or pair == "<=" or pair == ">=" then width = 2 end
            end
            if width == 0 then break end
            last = prefix_end(last + width + 1, 0)
            if not last then return nil, false end
        end
        local value, start = infer(last)
        return start == first and value or nil, true, last
    end
    local function schedule(names, schema, last, local_binding)
        local target = last + 1
        scheduled[target] = scheduled[target] or {}
        for position, name in ipairs(names) do
            scheduled[target][#scheduled[target] + 1] = {name = name, schema = position == 1 and schema or nil, local_binding = local_binding}
        end
    end
    local index = 1
    while index <= #tokens do
        for _, binding in ipairs(scheduled[index] or {}) do assign(binding.name, binding.schema, binding.local_binding) end
        local token, value = tokens[index], tokens[index].value
        if value == "function" and token.kind == "name" then
            local first = index + 1
            while first <= #tokens and first < index + 32 and tokens[first].value ~= "(" and
                (tokens[first].kind == "name" or tokens[first].value == "." or tokens[first].value == ":") do first = first + 1 end
            if tokens[first] and tokens[first].value == "(" and matching[first] then
                local finish, bindings, position = matching[first], {}, 0
                local input = first == index + 1 and callback_input(index)
                for parameter = first + 1, finish - 1 do
                    if tokens[parameter].kind == "name" then
                        position = position + 1
                        bindings[tokens[parameter].value] = position == 1 and input or false
                    end
                end
                if first > index + 1 and tokens[index + 1].kind == "name" then assign(tokens[index + 1].value, nil, false) end
                scopes[#scopes + 1] = {kind = "function", bindings = bindings}
                index = finish
            else return nil end
        elseif (value == "local" or value == "global") and token.kind == "name" then
            local at, names = index + 1, {}
            if tokens[at] and tokens[at].value == "function" then
                if tokens[at + 1] then assign(tokens[at + 1].value, nil, true) end
            else
                while tokens[at] and tokens[at].kind == "name" and not keywords[tokens[at].value] do
                    names[#names + 1] = tokens[at].value; at = at + 1
                    if tokens[at] and tokens[at].value == "<" then
                        while tokens[at] and tokens[at].value ~= ">" do at = at + 1 end
                        at = at + 1
                    end
                    if not tokens[at] or tokens[at].value ~= "," then break end
                    at = at + 1
                end
                local schema, complete, last
                if tokens[at] and tokens[at].value == "=" then schema, complete, last = initializer(at + 1)
                else complete = true end
                if complete then
                    if last then schedule(names, schema, last, true)
                    else for _, name in ipairs(names) do assign(name, nil, true) end end
                end
            end
        elseif value == "if" or value == "for" or value == "while" or value == "repeat" then
            local scope = {kind = value, bindings = {}, await_do = value == "for" or value == "while"}
            scopes[#scopes + 1] = scope
            if value == "for" then
                local at = index + 1
                while tokens[at] and tokens[at].kind == "name" and not keywords[tokens[at].value] do
                    scope.bindings[tokens[at].value] = false
                    if not tokens[at + 1] or tokens[at + 1].value ~= "," then break end
                    at = at + 2
                end
            elseif value == "repeat" then
                for _, existing in ipairs(scopes) do for key in next, existing.bindings do existing.bindings[key] = false end end
            end
        elseif value == "do" then
            if scopes[#scopes].await_do then scopes[#scopes].await_do = false
            else scopes[#scopes + 1] = {kind = "do", bindings = {}} end
        elseif value == "else" or value == "elseif" then
            if scopes[#scopes].kind == "if" then scopes[#scopes].bindings = {} end
        elseif value == "end" or value == "until" then
            if #scopes > 1 then scopes[#scopes] = nil end
        elseif token.kind == "name" and not keywords[value] and tokens[index + 1] and tokens[index + 1].value == "=" and
            not (tokens[index + 2] and tokens[index + 2].value == "=") and
            not (tokens[index - 1] and (tokens[index - 1].value == "." or tokens[index - 1].value == ":" or
                tokens[index - 1].value == "local" or tokens[index - 1].value == "{" or tokens[index - 1].value == ",")) then
            local schema, complete, last = initializer(index + 2)
            if complete then schedule({value}, schema, last, false) end
        end
        if #scopes > 64 then return nil end
        index = index + 1
    end
    return {infer = infer, lookup = lookup}
end
local function scoped_receiver(tokens, last, scope_tokens, scope_offset)
    local context = lexical_context(scope_tokens)
    if not context or not tokens[last] then return nil, false end
    local target, ending = tokens[last].last + (scope_offset or 0), nil
    for index = #scope_tokens, 1, -1 do if scope_tokens[index].last == target then ending = index; break end end
    if not ending then return nil, false end
    local schema, first = context.infer(ending)
    local local_first = last
    if first then
        local position = scope_tokens[first].first - (scope_offset or 0)
        for index = 1, last do if tokens[index].first >= position then local_first = index; break end end
    end
    if schema then return schema, true, local_first end
    local root = local_first
    while root > 2 and tokens[root - 1].value == "." and tokens[root - 2].kind == "name" do root = root - 2 end
    local _, bound = context.lookup(tokens[root].value)
    return nil, bound, root
end
local function schema_fields(fragment, schema)
    local fields = type(schema) == "table" and rawget(schema, "fields")
    local result = {}
    if type(fields) ~= "table" then return result end
    for index = 1, math.min(rawlen(fields), 64) do
        local entry = rawget(fields, index)
        if type(entry) == "table" then
            local name, field_type, description = rawget(entry, "name"), rawget(entry, "type"), rawget(entry, "description")
            if type(name) == "string" and name:sub(1, #fragment) == fragment then
                local label = name .. " : " .. (type(field_type) == "string" and field_type or "value")
                if rawget(entry, "optional") == true then label = label .. "?" end
                if type(description) == "string" and description ~= "" then label = label .. " — " .. description end
                result[#result + 1] = {name = name, label = label}
            end
        end
    end
    table.sort(result, function(a, b) return a.name < b.name end)
    return result
end

function lush.complete(source, cursor, pending)
    if type(source) ~= "string" then return {} end
    cursor = cursor == nil and #source or math.tointeger(cursor)
    if not cursor or cursor < 0 or cursor > #source then return {} end
    source = source:sub(1, cursor)
    local tokens, active = lex(source)
    local scope_tokens, scope_offset = tokens, 0
    if type(pending) == "string" and pending ~= "" and #pending + #source < 65536 then
        local scope_active
        scope_tokens, scope_active = lex(pending .. "\n" .. source)
        scope_offset = #pending + 1
        if scope_active and (scope_active.kind ~= "string" or not active) then return {} end
    end
    if active then
        if active.kind ~= "string" or active.value:find("\0", 1, true) then return {} end
        local result, add = result_set(active.first + 1)
        local last = tokens[#tokens]
        if last and last.value == "[" then
            local known, bound = scoped_receiver(tokens, #tokens - 1, scope_tokens, scope_offset)
            if bound then
                if known then
                    for _, entry in ipairs(schema_fields(active.value, known)) do
                        add(source:sub(1, active.first) .. quoted(entry.name, active.quote), entry.label)
                    end
                end
                return result
            end
        end
        if last and last.value == "(" then
            local target = receiver(tokens, #tokens - 1)
            local namespace = rawget(_G, "lush")
            if target == documented_help then
                local names = {"commands", "find"}
                for _, command in ipairs(rawget(namespace, "command_registry") or {}) do
                    names[#names + 1] = command.name
                end
                if registered_aliases then
                    for _, entry in ipairs(registered_aliases()) do names[#names + 1] = entry.name end
                end
                table.sort(names)
                for _, name in ipairs(names) do
                    if starts_with(name, active.value) then
                        add(source:sub(1, active.first) .. quoted(name, active.quote), name)
                    end
                end
                return result
            end
        end
        local executable, directories = string_context(tokens)
        local before = source:sub(1, active.first)
        local has_separator = active.value:find("/", 1, true) or
            (native.platform == "windows" and active.value:find("\\", 1, true))
        if executable and not has_separator then
            for _, name in ipairs(executable_names(active.value)) do
                add(before .. quoted(name, active.quote), name)
            end
        end
        for _, entry in ipairs(file_candidates(active.value,
            directories or (executable and not has_separator), executable)) do
            add(before .. quoted(entry.value, active.quote), entry.label)
        end
        return result
    end
    local last = tokens[#tokens]
    if not last or last.last ~= #source then return {} end
    local fragment, receiver_index, separator, fragment_start
    if last.kind == "name" then
        fragment, fragment_start = last.value, last.first
        local previous = tokens[#tokens - 1]
        if previous and (previous.value == "." or previous.value == ":") then
            receiver_index, separator = #tokens - 2, previous.value
        end
    elseif last.value == "." or last.value == ":" then
        fragment, fragment_start, receiver_index, separator = "", #source + 1, #tokens - 1, last.value
    else return {} end
    if receiver_index then
        local known, bound, first = scoped_receiver(tokens, receiver_index, scope_tokens, scope_offset)
        if bound then
            local result, add = result_set(tokens[first or receiver_index].first)
            if known and separator == "." then
                local before = source:sub(1, tokens[receiver_index].last) .. "."
                for _, entry in ipairs(schema_fields(fragment, known)) do add(before .. entry.name, entry.label) end
            end
            return result
        end
        local value, first = receiver(tokens, receiver_index)
        if value == nil or not first then return {} end
        local start = tokens[first].first
        local before = source:sub(1, start - 1)
        local namespace = source:sub(start, tokens[receiver_index].last)
        local result, add = result_set(start)
        if value == rawget(_G, "cmd") then
            for _, name in ipairs(executable_names(fragment)) do
                local replacement = identifier(name) and namespace .. "." .. name or
                    namespace .. '["' .. quoted(name) .. '"]'
                add(before .. replacement, name)
            end
        elseif type(value) == "table" then
            local names = {}
            for key in next, value do
                if type(key) == "string" and key:sub(1, #fragment) == fragment then names[#names + 1] = key end
            end
            table.sort(names)
            for _, name in ipairs(names) do
                if identifier(name) then add(before .. namespace .. separator .. name, name)
                elseif separator == "." then add(before .. namespace .. '["' .. quoted(name) .. '"]', name) end
            end
        end
        return result
    end
    if last.kind ~= "name" then return {} end
    local result, add = result_set(fragment_start)
    local names = {}
    for key in next, _G do
        if type(key) == "string" and identifier(key) and key:sub(1, #fragment) == fragment then names[key] = true end
    end
    for word in pairs(keywords) do if word:sub(1, #fragment) == fragment then names[word] = true end end
    local ordered = {}
    for name in pairs(names) do ordered[#ordered + 1] = name end
    table.sort(ordered)
    for _, name in ipairs(ordered) do add(source:sub(1, fragment_start - 1) .. name, name) end
    return result
end

lush.completion = {complete = lush.complete}
