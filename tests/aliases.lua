-- Pure-Lua alias registration, laziness and function identity regressions.
-- Run: build/lush --no-config tests/aliases.lua
local globals = _G
local assert, error, type, tostring, pcall, xpcall, select, print =
    assert, error, type, tostring, pcall, xpcall, select, print
local ipairs, pairs, next, rawget, rawset, rawequal, getmetatable, setmetatable =
    ipairs, pairs, next, rawget, rawset, rawequal, getmetatable, setmetatable
local table, string, debug = table, string, debug
assert(type(alias) == "function" and alias == lush.alias, "alias API is missing")
local checks = 0
local function equal(actual, expected)
    assert(actual == expected, tostring(actual) .. " ~= " .. tostring(expected))
    checks = checks + 1
end
local function rejects(callback)
    local ok, problem = pcall(callback)
    assert(not ok and type(problem) == "string" and #problem > 0, tostring(problem))
    checks = checks + 1
end

local native_execute = _lush.execute
local launches = 0
_lush.execute = function()
    launches = launches + 1
    error("registration and inspection must not execute external commands")
end
local ok, problem = xpcall(function()
    local called = 0
    local original = function(...)
        called = called + 1
        return select("#", ...), ...
    end
    equal(alias("alias_function_probe", original), nil)
    equal(alias_function_probe, original)
    equal(called, 0)
    local result = table.pack(alias_function_probe("one", nil, false))
    equal(result.n, 4)
    equal(result[1], 3)
    equal(result[2], "one")
    equal(result[3], nil)
    equal(result[4], false)
    equal(called, 1)
    local error_value = {}
    local broken = function() error(error_value) end
    alias("alias_error_probe", broken)
    local succeeded, thrown = pcall(alias_error_probe)
    equal(succeeded, false)
    equal(thrown, error_value)
    alias("alias_ls_probe", ls)
    equal(alias_ls_probe, ls)

    local fixed = {"alias-nonexistent-executable", "fixed argument", ""}
    alias("alias_exec_probe", fixed)
    fixed[1], fixed[2], fixed[3], fixed[4] = "changed", "changed", "changed", "extra"
    local first = alias_exec_probe("literal ; & $ |", "한글", "")
    equal(#first.commands, 1)
    equal(#first.commands[1], 6)
    equal(first.commands[1][1], "alias-nonexistent-executable")
    equal(first.commands[1][2], "fixed argument")
    equal(first.commands[1][3], "")
    equal(first.commands[1][4], "literal ; & $ |")
    equal(first.commands[1][5], "한글")
    equal(first.commands[1][6], "")
    first.commands[1][1], first.commands[1][2] = "mutated plan", "mutated plan"
    local second = alias_exec_probe()
    equal(#second.commands[1], 3)
    equal(second.commands[1][1], "alias-nonexistent-executable")
    equal(second.commands[1][2], "fixed argument")
    local original_cmd = cmd
    cmd = function() error("alias looked up a replaced command constructor") end
    local isolated = alias_exec_probe("still literal")
    cmd = original_cmd
    equal(isolated.commands[1][4], "still literal")
    alias("alias_numeric_probe", {"unused", 42})
    equal(alias_numeric_probe(17).commands[1][2], "42")
    equal(alias_numeric_probe(17).commands[1][3], "17")
    rejects(function() alias_exec_probe("before", nil, "after") end)
    rejects(function() alias_exec_probe(false) end)
    rejects(function() alias_exec_probe({}) end)
    rejects(function() alias_exec_probe("nul\0argument") end)
    equal(launches, 0)

    local bulk_function = function() return "bulk" end
    equal(alias{alias_bulk_function = bulk_function, alias_bulk_exec = {"bulk-nonexistent", "fixed"}}, nil)
    equal(alias_bulk_function, bulk_function)
    equal(alias_bulk_exec("extra").commands[1][3], "extra")
    local saved = function() return "unchanged" end
    alias("alias_atomic_saved", saved)
    rejects(function()
        alias{alias_atomic_saved = original, alias_atomic_new = original, alias_atomic_invalid = false}
    end)
    equal(alias_atomic_saved, saved)
    equal(rawget(_G, "alias_atomic_new"), nil)
    equal(rawget(_G, "alias_atomic_invalid"), nil)
    for _, invalid in ipairs{false, 42, "", "program --flag", {}, {""}, {"exe", false},
                            {[1] = "exe", [3] = "hole"}, {"exe", extra = "field"}, {"exe", "nul\0argument"}} do
        rejects(function() alias("alias_invalid_value", invalid) end)
    end
    rejects(function() alias("alias_invalid_value", nil) end)
    equal(rawget(_G, "alias_invalid_value"), nil)
    for _, name in ipairs{"", "two words", "bad-name", "a.b", "end", "global", "_G", "lush", "nul\0name", "한글"} do
        rejects(function() alias(name, original) end)
    end
    rejects(function() alias(false, original) end)
    rejects(function() alias(nil, original) end)
    rejects(function() alias{alias_atomic_new = original, ["bad-name"] = original} end)
    equal(rawget(_G, "alias_atomic_new"), nil)
    local hooks = 0
    local hidden_invalid = setmetatable({alias_atomic_new = original, alias_atomic_invalid = false}, {
        __pairs = function() hooks = hooks + 1; error("bulk __pairs executed") end,
        __index = function() hooks = hooks + 1; error("bulk __index executed") end,
        __len = function() hooks = hooks + 1; error("bulk __len executed") end,
    })
    rejects(function() alias(hidden_invalid) end)
    equal(hooks, 0)
    equal(rawget(_G, "alias_atomic_new"), nil)
    local invalid_argv = setmetatable({"unused", false}, getmetatable(hidden_invalid))
    rejects(function() alias("alias_invalid_value", invalid_argv) end)
    equal(hooks, 0)
    equal(launches, 0)

    equal(aliases, lush.aliases)
    local rows, external = aliases()
    for index, row in ipairs(rows) do
        if index > 1 then assert(rows[index - 1].name < row.name) end
        if row.name == "alias_exec_probe" then external = row end
        if row.name == "alias_function_probe" then equal(row.kind, "function"); equal(row.command, nil) end
    end
    equal(external.kind, "external")
    equal(external.command[1], "alias-nonexistent-executable")
    external.command[1] = "changed snapshot"
    rows[1].name = "changed snapshot"
    equal(alias_exec_probe().commands[1][1], "alias-nonexistent-executable")
    for _, row in ipairs(aliases()) do
        if row.name == "alias_exec_probe" then equal(row.command[1], "alias-nonexistent-executable") end
    end

    -- Completion and highlighting may inspect bindings, but never invoke them.
    local found = false
    for _, replacement in ipairs(lush.complete("alias_function_pr")) do
        if replacement == "alias_function_probe" then found = true end
    end
    equal(found, true)
    equal(lush.highlight("alias_function_probe()"), string.rep("5", #"alias_function_probe") .. "66")
    equal(help(alias_ls_probe), help(ls))
    assert(help("alias_ls_probe"):lower():find("alias", 1, true))
    assert(help("alias_function_probe"):find("alias_function_probe", 1, true))
    assert(help(alias_function_probe):find("alias_function_probe", 1, true))
    assert(help(alias_exec_probe):find("alias_exec_probe", 1, true))
    checks = checks + 4
    local function listed(name)
        local count = 0
        for _, row in ipairs(commands():collect()) do if row.name == name then count = count + 1 end end
        return count
    end
    equal(listed("alias_function_probe"), 1)
    alias_function_probe = "global replacement"
    for _, row in ipairs(aliases()) do assert(row.name ~= "alias_function_probe") end
    equal(listed("alias_function_probe"), 0)
    rejects(function() help("alias_function_probe") end)
    rejects(function() help(original) end)
    alias("alias_function_probe", original)
    equal(listed("alias_function_probe"), 1)
    local original_pwd = pwd
    alias("pwd", original)
    equal(listed("pwd"), 1)
    assert(help("pwd"):lower():find("alias", 1, true))
    pwd = original_pwd
    equal(listed("pwd"), 1)
    equal(help(pwd), help("pwd"))
    equal(called, 1)
    equal(launches, 0)

    -- Registering helper names must not redirect internal Flow validation or
    -- discovery through user aliases. Restore them before propagating failure.
    local names = {"getmetatable", "setmetatable", "pairs", "ipairs", "next", "rawget", "rawequal", "math", "type"}
    local saved, replacements, helper_calls = {}, {}, 0
    local forbidden = function()
        helper_calls = helper_calls + 1
        error("discovery invoked a helper-name alias")
    end
    for _, name in ipairs(names) do
        saved[name], replacements[name] = rawget(globals, name), forbidden
    end
    local discovered, discovery_problem = xpcall(function()
        alias(replacements)
        local records = commands():collect()
        equal(type(records), "table")
        assert(#records > 0)
        local visible = {}
        for _, record in ipairs(records) do
            assert(type(record) == "table" and type(record.name) == "string" and
                   type(record.category) == "string" and type(record.description) == "string")
            visible[record.name] = true
        end
        checks = checks + 1
        for _, name in ipairs(names) do equal(visible[name], true) end
        for _, topic in ipairs{"alias_exec_probe", "ls", "lush", ""} do
            local document = help(topic)
            equal(type(document), "string")
            assert(#document > 0)
        end
        equal(type(help(alias_function_probe)), "string")
        equal(type(help("commands"):collect()), "table")
        local function completes(source, expected)
            local found = false
            for _, replacement in ipairs(lush.complete(source)) do
                if replacement == expected then found = true end
            end
            equal(found, true)
        end
        completes("alias_function_pr", "alias_function_probe")
        completes('help("alias_exec_pr', 'help("alias_exec_probe')
        completes('lush.help("alias_function_pr', 'lush.help("alias_function_probe')
        equal(helper_calls, 0)
    end, debug.traceback)
    for _, name in ipairs(names) do rawset(globals, name, saved[name]) end
    assert(discovered, discovery_problem)
    equal(helper_calls, 0)
    equal(launches, 0)
end, debug.traceback)
_lush.execute = native_execute
assert(ok, problem)
print("aliases: " .. checks .. " checks passed")
