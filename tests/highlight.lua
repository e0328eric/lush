-- Exercise the lexer embedded in the executable, including incomplete input.
assert(type(lush.highlight) == "function", "embedded highlighter is missing")
local highlight = lush.highlight
local checks = 0
local function equal(actual, expected, source)
    assert(actual == expected, string.format("%q: %q ~= %q", source or "", actual, expected))
    checks = checks + 1
end
local function parts(values)
    local source, mask = {}, {}
    for i, value in ipairs(values) do
        source[i], mask[i] = value[1], string.rep(value[2], #value[1])
    end
    source, mask = table.concat(source), table.concat(mask)
    equal(highlight(source), mask, source)
end
local function uniform(source, category)
    equal(highlight(source), string.rep(category, #source), source)
end
local function valid_mask(source)
    local mask = highlight(source)
    assert(type(mask) == "string" and #mask == #source and not mask:find("[^0-7]"),
        string.format("invalid mask for %q: %q", source, mask))
    checks = checks + 1
end

uniform("", "0")
uniform(" \t\r\n\v\f", "0")
for name in ("and break do else elseif end false for function global goto if in local nil " ..
             "not or repeat return then true until while"):gmatch("%S+") do uniform(name, "1") end
uniform("globalglobal", "0")
uniform("nil_value", "0")
uniform("trueish", "0")
uniform("cat", "5")
uniform("open", "5")
parts{{"local", "1"}, {" x ", "0"}, {"=", "6"}, {" ", "0"}, {"print", "5"},
      {"(", "6"}, {'"hello"', "2"}, {",", "6"}, {" ", "0"}, {"42", "3"}, {")", "6"}}
parts{{"math", "5"}, {".", "6"}, {"floor", "5"}, {"(", "6"}, {"3.5", "3"}, {")", "6"}}
parts{{"obj", "0"}, {":", "6"}, {"method", "5"}, {"(", "6"}, {'"x"', "2"}, {")", "6"}}
parts{{"function", "1"}, {" ", "0"}, {"plain", "5"}, {"(", "6"}, {"x", "0"}, {")", "6"},
      {" ", "0"}, {"return", "1"}, {" x ", "0"}, {"end", "1"}}
parts{{"foo", "5"}, {" ", "0"}, {'"string-call"', "2"}}
parts{{"foo", "5"}, {" ", "0"}, {"{", "6"}, {"x", "0"}, {"=", "6"}, {"1", "3"}, {"}", "6"}}
parts{{"foo", "5"}, {" ", "0"}, {"[=[long-call]=]", "2"}}
parts{{"foo", "5"}, {" ", "0"}, {"-- comment", "4"}, {"\n", "0"},
      {"(", "6"}, {"1", "3"}, {")", "6"}}
parts{{"foo", "5"}, {" ", "0"}, {"--[[ comment ]]", "4"}, {" ", "0"}, {"{", "6"}, {"}", "6"}}
parts{{"a ", "0"}, {"--[[ comment ]]", "4"}, {" ", "0"}, {"+", "6"}, {" b", "0"}}
parts{{"table", "5"}, {".", "6"}, {"field", "0"}, {"=", "6"}, {"1", "3"}}
parts{{"cmd", "5"}, {".", "6"}, {"git", "5"}, {"(", "6"}, {"'status'", "2"}, {")", "6"}}

for _, literal in ipairs({"0", "1", "12345", "0.5", ".5", "1.", "12e3", "12E-3", "12e+3",
    "1e999", "0xff", "0XfF", "0x1.8", "0x.8", "0x1p3", "0x1.8P-3", "0x1.p+3"}) do
    assert(load("return " .. literal), literal)
    uniform(literal, "3")
end
for _, literal in ipairs({"0x", "0X", "0x.", "1e", "1E+", "1e-", "0x1p", "0x1P-"}) do
    uniform(literal, "3") -- unfinished, potentially valid input at the caret
end
for _, literal in ipairs({"1..2", "1...", "1.2.3", "0xZZ", "0b101", "123hello", "123_foo", "1e+x"}) do
    assert(not load("return " .. literal), literal)
    uniform(literal, "7")
end
parts{{"1", "3"}, {" ", "0"}, {"..", "6"}, {" ", "0"}, {"2", "3"}}
parts{{"1", "3"}, {" ", "0"}, {"..", "6"}, {" ", "0"}, {".5", "3"}}
parts{{"...", "6"}, {".5", "3"}}
parts{{"0xe", "3"}, {"+", "6"}, {"1", "3"}}
parts{{"0x1E", "3"}, {"-", "6"}, {"2", "3"}}
parts{{"-", "6"}, {"1", "3"}, {"+", "6"}, {"2", "3"}, {"/", "6"}, {"3", "3"}}
parts{{"1", "3"}, {"-- after-number", "4"}}
uniform("+-*/%^#&~|<>=;:,{}]().", "6")
for operator in ("== ~= <= >= << >> // :: .. ..."):gmatch("%S+") do uniform(operator, "6") end
parts{{"==", "6"}, {" ", "0"}, {"~=" , "6"}, {" ", "0"}, {"//", "6"}}
uniform("[", "6")
uniform("[===", "2")
parts{{"[=", "7"}, {"bad", "0"}}
uniform("@$?\\", "7")
uniform("\0", "7")
parts{{"#", "6"}, {"!", "7"}, {"lua", "0"}}

uniform("-- comment keyword local 123 'text'", "4")
parts{{"-- comment", "4"}, {"\r\n", "0"}, {"local", "1"}, {" x", "0"}}
uniform("--[===unfinished line comment", "4")
for count = 0, 16 do
    local equals = string.rep("=", count)
    local opening, closing = "[" .. equals .. "[", "]" .. equals .. "]"
    local body = "local -- text\n123 'quoted' 한글 ]" .. string.rep("=", count + 1) .. "] "
    uniform(opening .. body .. closing, "2")
    uniform(opening .. body, "2")
    uniform("--" .. opening .. body .. closing, "4")
    uniform("--" .. opening .. body, "4")
end
parts{{"[=[abc]]def]=]", "2"}, {" ", "0"}, {"local", "1"}}
parts{{"--[==[a]=]b]==]", "4"}, {" ", "0"}, {"42", "3"}}

for _, literal in ipairs({[["plain"]], [['single']], [["escaped\"quote"]],
    [["\a\b\f\n\r\t\v\\\"\'\x41\u{1f600}\000\255"]],
    [["\u{7fffffff}"]], [["\u{d800}"]], [["unfinished]], [["trailing\]],
    [["\x]], [["\xA]], [["\u]], [["\u{]], [["\u{123]],
    '"escaped\\\nnewline"', '"escaped\\\r\nnewline"', '"zapped\\z \t\r\n text"',
    '"한글 ☃"', '"raw\0byte"', '"\255"'}) do uniform(literal, "2") end
parts{{'"bad', "2"}, {'\\q', "7"}, {'"', "2"}}
parts{{'"bad', "2"}, {'\\한', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\256', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\xG', "7"}, {'1"', "2"}}
parts{{'"', "2"}, {'\\xAG', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\x', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\u{}', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\u{ZZ}', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\u{80000000}', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\u{ffffffffffffffff}', "7"}, {'"', "2"}}
parts{{'"', "2"}, {'\\u', "7"}, {'X"', "2"}}
parts{{'"raw', "7"}, {"\n", "0"}, {"x", "5"}, {'"', "2"}}
parts{{"local", "1"}, {" ", "0"}, {"한글", "7"}, {" ", "0"}, {"=", "6"},
      {" ", "0"}, {'"☃"', "2"}}

-- Every prefix can occur while a user is typing or while a chunk is pending,
-- including prefixes cut in the middle of a multi-byte UTF-8 scalar.
local examples = {
    'local message = "한글 ☃\\n"; print(message)',
    'global answer = 0x1.2p-3; if answer < .5 then cmd.git("status") end',
    '--[====[ comment\n nested [=[ different ]=] ]====]\nreturn true',
    'local s = [==[long\n한글]=]still string]==]; print(s)',
    'local s = "escapes \\x41\\u{1f600}\\255\\z \n next"',
    'local bad = "\\q"; local also = 1..2; f({x=42})',
    'for i=1,10 do print(i // 2, i << 1, "text") end',
}
for _, example in ipairs(examples) do
    for length = 0, #example do valid_mask(example:sub(1, length)) end
end
for value = 0, 255 do valid_mask(string.char(value)) end

local original_load, original_dofile, original_require, original_cmd = load, dofile, require, cmd
local called = false
local function forbidden() called = true; error("highlighter executed input") end
load, dofile, require = forbidden, forbidden, forbidden
cmd = setmetatable({}, {__index = forbidden})
highlight_trap = forbidden
local ok, problem = pcall(function()
    valid_mask('highlight_trap(); os.execute("must never run"); require("never"); cmd.anything()')
    valid_mask('dofile("never"); load("error()")()')
end)
load, dofile, require, cmd = original_load, original_dofile, original_require, original_cmd
highlight_trap = nil
assert(ok, problem)
equal(called, false)
equal(highlight(false), "")
equal(highlight({}), "")
print("highlight: " .. checks .. " checks passed")
