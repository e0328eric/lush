-- Exercise the public component toolkit embedded in the executable.
assert(type(lush.theme) == "table", "embedded theme utility library is missing")
assert(rawget(lush, "themes") == nil, "named theme compositions were baked into the executable")
assert(rawget(lush.theme, "sources") == nil, "theme reference URLs were baked into the utility module")
local t, checks = lush.theme, 0
local function equal(actual, expected)
    assert(actual == expected, string.format("%q ~= %q", actual, expected))
    checks = checks + 1
end
local function contains(actual, expected)
    assert(actual:find(expected, 1, true), string.format("%q does not contain %q", actual, expected))
    checks = checks + 1
end
local function rejects(callback, name)
    local ok, problem = pcall(callback)
    assert(not ok and tostring(problem):find(name, 1, true), tostring(problem))
    checks = checks + 1
end
local function plain(value) return (value:gsub("\27%[[0-9;]*m", "")) end
local function only_sgr(value)
    local stripped = plain(value)
    assert(not stripped:find("[%z\1-\31\127]"), string.format("non-SGR control in %q", value))
    assert(utf8.len(stripped), "invalid UTF-8 output")
    checks = checks + 1
end
local function component(value, context, options)
    return t.render_components({value}, context or {}, options or {icons = false})
end
local gib = 1073741824
local context = {
    cwd = "/home/alma/project", home = "/home/alma", user = "alma", host = "workstation",
    platform = "unix", is_admin = true, time = "12:34:56", last_status = 0,
    execution_ms = 2250, python_env = "project-venv", battery = {percent = 73, charging = false},
    memory = {used = 8 * gib, total = 16 * gib},
    git = {branch = "main", dirty = 2, staged = 1, ahead = 3, behind = 4, stash = 5},
}
local context_before = json.encode(context)
local options = {icons = false}
local plain_prompt = t.prompt{input = {t.path(), t.text(" > ")}}
local default = t.render(plain_prompt, context, options)
equal(#default.lines, 0)
equal(default.input, "~/project > ")
equal(t.render(plain_prompt, context, options).input, default.input)

-- Example compositions are ordinary, editable Lua files. Loading one returns
-- a descriptor; it does not install any named registry into the core library.
local own_source = debug.getinfo(1, "S").source
local filename = own_source:sub(1, 1) == "@" and own_source:sub(2) or arg[0]
local root = path.dirname(path.dirname(filename))
local themes = {plain = plain_prompt}
for _, name in ipairs{"powerlevel10k_classic", "easy-term", "iterm2"} do
    themes[name] = source(path.join(root, "themes", name .. ".lua"))
    equal(type(themes[name]), "table")
    equal(themes[name].kind, "prompt")
    rejects(function() t.render(name, context, options) end, "prompt descriptor")
end
equal(rawget(lush, "themes"), nil)
equal(rawget(t, "sources"), nil)
equal(component(t.path(), {cwd = "/home/alma2/project", home = "/home/alma"}), "/home/alma2/project")
equal(component(t.path(), {cwd = "/home/alma", home = "/home/alma/"}), "~")
equal(component(t.path(), {cwd = "C:\\Users\\Alma\\project", home = "c:\\users\\alma", platform = "windows"}), "~\\project")
equal(component(t.path{mode = "folder"}, context), "project")
equal(component(t.path{mode = "folder"}, {cwd = "/"}), "/")
equal(component(t.path{home_shorten = false}, context), "/home/alma/project")
equal(component(t.os(), {platform = "windows"}), "Windows")
equal(component(t.os(), {platform = "macos"}), "macOS")
equal(component(t.os(), {platform = "unix"}), "Linux")
equal(component(t.os{icon = false}, {platform = "windows"}, {icons = true}), "Windows")
equal(component(t.os{icon = "W"}, {platform = "windows"}, {icons = true}), "W")
equal(component(t.os{label = "host-os", icon = false}, context), "host-os")
equal(component(t.session(), context), "alma@workstation")
equal(component(t.session{user_only = true}, context), "alma")
equal(component(t.session(), {}), "")
equal(component(t.time(), context), "12:34:56")
equal(component(t.time{prefix = "[", suffix = "]"}, {}), "")
equal(component(t.root(), context), "admin")
equal(component(t.root(), {is_admin = false}), "")
equal(component(t.status(), {last_status = 0}), ">")
equal(component(t.status{show_code = true}, {last_status = 7}), "> 7")
equal(component(t.status{always = false}, {last_status = 0}), "")
equal(component(t.status{success_text = "✓", error_text = "✗", ascii = "status"}, {last_status = 7}), "status")
equal(component(t.execution_time(), context), "2.25s")
equal(component(t.execution_time(), {execution_ms = 149}), "")
equal(component(t.execution_time{threshold_ms = 0}, {execution_ms = 0}), "0ms")
equal(component(t.execution_time(), {execution_ms = 500}), "500ms")
equal(component(t.execution_time(), {}), "")
equal(component(t.python(), context), "py:project-venv")
equal(component(t.python(), {}), "")
equal(component(t.battery(), context), "bat:73%")
equal(component(t.battery(), {battery = {percent = 20, charging = true}}), "charge:20%")
equal(component(t.battery{icon = false}, {battery = 30}), "30%")
equal(component(t.battery(), {}), "")
equal(component(t.memory(), context), "RAM: 8.0/16.0GB")
equal(component(t.memory(), {}), "")
equal(component(t.git{icon = false}, context), "main *2 +1 ^3 v4 stash:5")
equal(component(t.git(), {git = {branch = "main"}}), "git:main")
equal(component(t.git{icon = false, branch_limit = 2}, {git = {branch = "한글branch"}}), "한글")
equal(component(t.git{show_counts = false}, context), "git:main")
equal(component(t.git{prefix = "[", suffix = "]"}, {}), "")
equal(component(t.git(), context, {icons = false, git = false}), "")
equal(component(t.session(), context, {icons = false, session = false}), "")
equal(component(t.time(), context, {icons = false, time = false}), "")
equal(component(t.status(), context, {icons = false, status = false}), "")

local tinted = component(t.text("hello", {fg = "#abc", bg = "#123456", bold = true, prefix = "[", suffix = "]"}))
contains(tinted, "1;38;2;170;187;204;48;2;18;52;86m")
equal(plain(tinted), "[hello]")
only_sgr(tinted)
equal(component(t.text("x", {fg = false, bg = "transparent"})), "x")
local state = t.status{success_fg = "#00ff00", error_fg = "#ff0000"}
contains(component(state, {last_status = 0}), "38;2;0;255;0m")
contains(component(state, {last_status = 1}), "38;2;255;0;0m")
local original_status = lush.last_status
lush.last_status = 7
contains(component(state), "38;2;255;0;0m")
lush.last_status = original_status
equal(component(t.status{success_fg = "#00ff00"}, {last_status = 7}), ">")
local git_style = t.git{bg = "#000001", dirty_bg = "#000002", ahead_bg = "#000003",
    behind_bg = "#000004", diverged_bg = "#000005"}
contains(component(git_style, {git = {branch = "x", dirty = true}}), "48;2;0;0;2m")
contains(component(git_style, {git = {branch = "x", ahead = 1}}), "48;2;0;0;3m")
contains(component(git_style, {git = {branch = "x", behind = 1}}), "48;2;0;0;4m")
contains(component(git_style, {git = {branch = "x", ahead = 1, behind = 1}}), "48;2;0;0;5m")

local appearance = {fg = "#123456"}
local saved = t.text("stable", appearance)
appearance.fg = "#ffffff"
contains(component(saved), "38;2;18;52;86m")
local common_path = t.path{fg = "#00ffaa"}
local custom = t.prompt{rows = {
    t.row{left = {t.text("CUSTOM "), common_path}, right = {t.time()}},
    t.row{left = {t.git()}, right = {t.execution_time()}},
}, input = {t.text("> ", {fg = "#ff00ff"})}}
local rendered = t.render(custom, context, options)
equal(#rendered.lines, 2)
equal(plain(rendered.lines[1].left), "CUSTOM ~/project")
equal(rendered.lines[1].right, "12:34:56")
equal(rendered.lines[2].right, "2.25s")
equal(plain(rendered.input), "> ")
equal(json.encode(context), context_before)

local chain = t.chain({t.text("a", {fg = "#ffffff", bg = "#ff0000"}),
    t.git{bg = "#00ff00"}, t.text("b", {bg = "#0000ff"})})
local joined = component(chain, {})
equal(plain(joined), "a>b>")
contains(joined, "38;2;255;0;0;48;2;0;0;255m")
local right = component(t.chain({t.text("one", {bg = "#ff0000"}), t.text("two", {bg = "#00ff00"})},
    {side = "right", leading = true, trailing = false}))
equal(plain(right), "<one<two")
only_sgr(right)
equal(component(t.separator("|", {fg = "#abc"})):gsub("\27%[[0-9;]*m", ""), "|")

equal(t.sanitize("A\27[2JB\27]0;title\7C\27Ppayload\27\\D"), "ABCD")
equal(t.sanitize("A\0\7B\n\r\tC\127"), "AB   C")
equal(t.sanitize("A" .. utf8.char(0x9b) .. "B"), "AB")
equal(t.sanitize("A\255B"), "A�B")
equal(t.sanitize("한글 ☃"), "한글 ☃")
local metamethod_called = false
equal(t.sanitize(setmetatable({}, {__tostring = function() metamethod_called = true; return "unsafe" end})), "")
equal(metamethod_called, false)
local injected = {
    cwd = "/tmp/\27[31mproject\27[0m", user = "a\27[2J", host = "work\nstation",
    platform = "windows", time = "12:00\27]0;bad\7", git = {branch = "main\27[?25l"},
    python_env = "venv\27Pbad\27\\", battery = {percent = 65}, last_status = 7,
}
for _, name in ipairs{"plain", "powerlevel10k_classic", "easy-term", "iterm2"} do
    local result = t.render(themes[name], injected, {icons = false})
    equal(type(themes[name]), "table")
    equal(themes[name].kind, "prompt")
    equal(#result.lines, name == "plain" and 0 or 1)
    only_sgr(result.input)
    for _, row in ipairs(result.lines) do only_sgr(row.left); only_sgr(row.right) end
end
for _, name in ipairs{"powerlevel10k_classic", "easy-term", "iterm2"} do
    local result = t.render(themes[name], context, {icons = false, git = false})
    contains(plain(result.lines[1].left), name == "easy-term" and "project" or "~/project")
    contains(plain(result.lines[1].right), "12:34:56")
    assert(not plain(result.lines[1].left):find("main", 1, true))
    for _, value in ipairs{result.lines[1].left, result.lines[1].right, result.input} do
        for _, code in utf8.codes(plain(value)) do assert(code < 0xe000 or code > 0xf8ff, "Nerd Font icon with icons=false") end
        only_sgr(value)
    end
    local minimal = t.render(themes[name], {cwd = "/repo", platform = "unix", last_status = 0}, {icons = false})
    equal(plain(minimal.lines[1].right), "")
end

rejects(function() t.text({}) end, "theme.text")
rejects(function() t.path("bad") end, "theme.path")
rejects(function() t.text("x", {fg = "red"}) end, "color")
rejects(function() t.text("x", {prefix = function() end}) end, "prefix")
rejects(function() t.path{mode = "bad"} end, "mode")
rejects(function() t.git{branch_limit = math.huge} end, "branch_limit")
rejects(function() t.execution_time{threshold_ms = -1} end, "threshold_ms")
rejects(function() t.row{left = {42}} end, "theme.row")
rejects(function() t.prompt{rows = {t.row{}, t.row{}, t.row{}, t.row{}, t.row{}}} end, "four")
rejects(function() t.chain({}, {side = "up"}) end, "side")
rejects(function() t.chain({}, {separator = false}) end, "separator")
rejects(function() t.chain({t.chain{t.text("x")}}) end, "chain")
rejects(function() t.render({}, context) end, "theme.render")
rejects(function() t.render("plain", context) end, "prompt descriptor")
rejects(function() t.render(plain_prompt, false) end, "context")
rejects(function() t.render(plain_prompt, context, false) end, "options")
rejects(function() t.render(plain_prompt, context, {icons = "no"}) end, "icons")

local original_date, original_execute, original_popen, original_context = os.date, os.execute, io.popen, _lush.prompt_context
local called = false
local function forbidden() called = true; error("theme renderer called a system/process function") end
os.date, os.execute, io.popen, _lush.prompt_context = forbidden, forbidden, forbidden, forbidden
local ok, problem = xpcall(function()
    for _, name in ipairs{"plain", "powerlevel10k_classic", "easy-term", "iterm2"} do
        t.render(themes[name], context, options)
    end
end, debug.traceback)
os.date, os.execute, io.popen, _lush.prompt_context = original_date, original_execute, original_popen, original_context
assert(ok, problem)
equal(called, false)
print("theme: " .. checks .. " checks passed")
