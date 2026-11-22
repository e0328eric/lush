-- A tolerant Lua 5.5 lexer for the interactive editor. The result contains one
-- ASCII category digit for every source byte, including every UTF-8 byte.
-- No source is loaded, evaluated, or resolved through a Lua/user namespace.
local byte, sub, find, rep = string.byte, string.sub, string.find, string.rep
local concat, number, kind = table.concat, tonumber, type
local keywords, builtins = {}, {}
for name in
    (
        "and break do else elseif end false for function global goto if in local nil "
        .. "not or repeat return then true until while"
    ):gmatch("%S+")
do
    keywords[name] = true
end
for name in
    (
        "assert collectgarbage dofile error getmetatable ipairs load loadfile next pairs "
        .. "pcall print rawequal rawget rawlen rawset require select setmetatable tonumber "
        .. "tostring type warn xpcall coroutine debug io math os package string table utf8 "
        .. "lush alias aliases cmd ls sl pwd cd env run capture pipe stream where filter each map get take "
        .. "skip sort_by lines from_lines collect count to_json from_json to_text from to "
        .. "cat open save show echo exit help foreach"
    ):gmatch("%S+")
do
    builtins[name] = true
end
-- The command catalog is loaded before this module, so added builtins share
-- highlighting without inspecting or evaluating the user's input namespace.
for _, command in ipairs(lush.command_registry or {}) do
    local name = command.name:match("^[A-Za-z_][A-Za-z_0-9]*")
    if name then
        builtins[name] = true
    end
end

local function digit(c)
    return c and c >= 48 and c <= 57
end
local function hex(c)
    return digit(c) or (c and ((c >= 65 and c <= 70) or (c >= 97 and c <= 102)))
end
local function alpha(c)
    return c and ((c >= 65 and c <= 90) or (c >= 97 and c <= 122) or c == 95)
end
local function space(c)
    return c == 32 or c == 9 or c == 10 or c == 11 or c == 12 or c == 13
end
local function continuation(c)
    return c and c >= 128 and c <= 191
end
local function long_open(source, at)
    if byte(source, at) ~= 91 then
        return nil
    end
    local next_byte = at + 1
    while byte(source, next_byte) == 61 do
        next_byte = next_byte + 1
    end
    if byte(source, next_byte) == 91 then
        return sub(source, at + 1, next_byte - 1), next_byte + 1
    end
    return nil, next_byte
end
local simple_escape = {
    [97] = true,
    [98] = true,
    [102] = true,
    [110] = true,
    [114] = true,
    [116] = true,
    [118] = true,
    [92] = true,
    [34] = true,
    [39] = true,
}

-- A numeral can be a valid prefix while it is still being typed. Keep those
-- final prefixes numeric; definite malformed numerals such as 1..2 are errors.
local function unfinished_number(text)
    if text == "0x" or text == "0X" or text == "0x." or text == "0X." then
        return true
    end
    local mantissa = text:match("^(.-)[eE][+%-]?$")
    if mantissa and number(mantissa) ~= nil then
        return true
    end
    mantissa = text:match("^(0[xX].-)[pP][+%-]?$")
    return mantissa ~= nil and number(mantissa) ~= nil
end

function lush.highlight(source)
    if kind(source) ~= "string" then
        return ""
    end
    local length, at = #source, 1
    local spans, tokens = {}, {}
    local function span(first, last, category)
        if last < first then
            return
        end
        local value = { first = first, last = last, category = category }
        spans[#spans + 1] = value
        return value
    end
    local function token(first, last, category, token_kind)
        local value = span(first, last, category)
        value.kind, value.value = token_kind, sub(source, first, last)
        tokens[#tokens + 1] = value
        return value
    end
    local function quoted_string(first, quote)
        local cursor, errors = first + 1, {}
        local function bad(start, finish)
            errors[#errors + 1] = { start, finish }
        end
        local newline = false
        while cursor <= length do
            local c = byte(source, cursor)
            if c == quote then
                cursor = cursor + 1
                break
            end
            if c == 10 or c == 13 then
                newline = true
                break
            end
            if c ~= 92 then
                cursor = cursor + 1
            else
                local start, escaped = cursor, byte(source, cursor + 1)
                if escaped == nil then
                    cursor = length + 1
                elseif simple_escape[escaped] then
                    cursor = cursor + 2
                elseif escaped == 10 or escaped == 13 then
                    cursor = cursor + 2
                    if escaped == 13 and byte(source, cursor) == 10 then
                        cursor = cursor + 1
                    end
                elseif escaped == 122 then -- \z skips all following whitespace.
                    cursor = cursor + 2
                    while space(byte(source, cursor)) do
                        cursor = cursor + 1
                    end
                elseif escaped == 120 then -- \xHH
                    cursor = cursor + 2
                    local digits, invalid = 0, false
                    while digits < 2 and cursor <= length do
                        local current = byte(source, cursor)
                        if hex(current) then
                            digits = digits + 1
                            cursor = cursor + 1
                        else
                            invalid = true
                            if current ~= quote and current ~= 10 and current ~= 13 then
                                cursor = cursor + 1
                            end
                            break
                        end
                    end
                    if invalid then
                        bad(start, cursor - 1)
                    end
                elseif escaped == 117 then -- \u{HEX}, Lua permits values through 0x7fffffff.
                    cursor = cursor + 2
                    if cursor <= length and byte(source, cursor) ~= 123 then
                        bad(start, cursor - 1)
                    elseif cursor <= length then
                        cursor = cursor + 1
                        local digits = cursor
                        while hex(byte(source, cursor)) do
                            cursor = cursor + 1
                        end
                        local finish = byte(source, cursor)
                        if finish == 125 then
                            local spelling = sub(source, digits, cursor - 1)
                            local significant = spelling:gsub("^0+", "")
                            -- tonumber(hex, 16) wraps very long Lua integers.
                            -- Bound the spelling before converting it.
                            local code = #spelling > 0
                                and (
                                    #significant == 0 and 0
                                    or (#significant <= 8 and number(significant, 16))
                                )
                            cursor = cursor + 1
                            if not code or code > 0x7fffffff then
                                bad(start, cursor - 1)
                            end
                        elseif cursor <= length then
                            -- Recover through a malformed escape's closing brace,
                            -- without swallowing the containing quote/newline.
                            while
                                cursor <= length
                                and byte(source, cursor) ~= 125
                                and byte(source, cursor) ~= quote
                                and byte(source, cursor) ~= 10
                                and byte(source, cursor) ~= 13
                            do
                                cursor = cursor + 1
                            end
                            if byte(source, cursor) == 125 then
                                cursor = cursor + 1
                            end
                            bad(start, cursor - 1)
                        end
                    end
                elseif digit(escaped) then
                    cursor = cursor + 1
                    local digits = cursor
                    while cursor - digits < 3 and digit(byte(source, cursor)) do
                        cursor = cursor + 1
                    end
                    if number(sub(source, digits, cursor - 1)) > 255 then
                        bad(start, cursor - 1)
                    end
                else
                    cursor = cursor + 2
                    while continuation(byte(source, cursor)) do
                        cursor = cursor + 1
                    end
                    bad(start, cursor - 1)
                end
            end
        end
        local last = cursor - 1
        if newline then
            span(first, last, "7")
        else
            local first_part = first
            for _, range in ipairs(errors) do
                span(first_part, range[1] - 1, "2")
                span(range[1], range[2], "7")
                first_part = range[2] + 1
            end
            span(first_part, last, "2")
        end
        tokens[#tokens + 1] = { first = first, last = last, kind = "string" }
        return cursor
    end
    local function numeral(first, leading_dot)
        local cursor = first + (leading_dot and 1 or 0)
        local first_digit, exponent = byte(source, cursor), "eE"
        cursor = cursor + 1
        if first_digit == 48 and (byte(source, cursor) == 120 or byte(source, cursor) == 88) then
            exponent, cursor = "pP", cursor + 1
        end
        while cursor <= length do
            local c = byte(source, cursor)
            if c == byte(exponent, 1) or c == byte(exponent, 2) then
                cursor = cursor + 1
                if byte(source, cursor) == 43 or byte(source, cursor) == 45 then
                    cursor = cursor + 1
                end
            elseif hex(c) or c == 46 then
                cursor = cursor + 1
            else
                break
            end
        end
        if alpha(byte(source, cursor)) then
            repeat
                cursor = cursor + 1
            until not alpha(byte(source, cursor)) and not digit(byte(source, cursor))
        end
        local text = sub(source, first, cursor - 1)
        local category = number(text) ~= nil and "3"
            or (cursor > length and unfinished_number(text) and "3" or "7")
        token(first, cursor - 1, category, "number")
        return cursor
    end

    while at <= length do
        local first, c = at, byte(source, at)
        if space(c) then
            repeat
                at = at + 1
            until not space(byte(source, at))
            span(first, at - 1, "0")
        elseif c == 45 and byte(source, at + 1) == 45 then
            local equals, body = long_open(source, at + 2)
            if equals ~= nil then
                local _, finish = find(source, "]" .. equals .. "]", body, true)
                at = finish and finish + 1 or length + 1
            else
                at = at + 2
                while at <= length and byte(source, at) ~= 10 and byte(source, at) ~= 13 do
                    at = at + 1
                end
            end
            span(first, at - 1, "4")
        elseif c == 34 or c == 39 then
            at = quoted_string(first, c)
        elseif c == 91 then
            local equals, body = long_open(source, at)
            if equals ~= nil then
                local _, finish = find(source, "]" .. equals .. "]", body, true)
                at = finish and finish + 1 or length + 1
                token(first, at - 1, "2", "string")
            elseif body > at + 1 then
                at = body
                token(first, at - 1, at > length and "2" or "7", "invalid")
            else
                at = at + 1
                token(first, first, "6", "operator")
            end
        elseif alpha(c) then
            repeat
                at = at + 1
            until not alpha(byte(source, at)) and not digit(byte(source, at))
            local name = sub(source, first, at - 1)
            token(
                first,
                at - 1,
                keywords[name] and "1" or "0",
                keywords[name] and "keyword" or "name"
            )
        elseif digit(c) or (c == 46 and digit(byte(source, at + 1))) then
            at = numeral(first, c == 46)
        elseif c == 46 and byte(source, at + 1) == 46 then
            at = at + 2
            if byte(source, at) == 46 then
                at = at + 1
            end
            token(first, at - 1, "6", "operator")
        elseif find("+-*/%^#&~|<>=;:,{}]().", sub(source, at, at), 1, true) then
            at = at + 1
            local next_byte = byte(source, at)
            if
                (c == 61 or c == 60 or c == 62 or c == 126) and next_byte == 61
                or (c == 60 or c == 62 or c == 47 or c == 58) and next_byte == c
            then
                at = at + 1
            end
            token(first, at - 1, "6", "operator")
        else
            at = at + 1
            while continuation(byte(source, at)) do
                at = at + 1
            end
            token(first, at - 1, "7", "invalid")
        end
    end
    for index, value in ipairs(tokens) do
        if value.kind == "name" then
            local following = tokens[index + 1]
            if
                builtins[value.value]
                or (
                    following
                    and (
                        following.kind == "string"
                        or following.value == "("
                        or following.value == "{"
                    )
                )
            then
                value.category = "5"
            end
        end
    end
    local result = {}
    for index, value in ipairs(spans) do
        result[index] = rep(value.category, value.last - value.first + 1)
    end
    return concat(result)
end

lush.highlight_categories = {
    plain = "0",
    keyword = "1",
    string = "2",
    number = "3",
    comment = "4",
    call = "5",
    operator = "6",
    error = "7",
}
