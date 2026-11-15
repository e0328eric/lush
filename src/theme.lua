-- Reusable prompt components. Constructors build descriptors; rendering uses
-- only the supplied context and emits text plus SGR, never terminal commands.
local theme = {}
lush.theme = theme
local native = assert(_lush)
local read_theme_file, theme_path, compile_theme = native.theme_read, native.path, native.theme_compile
local pcall = pcall -- trusted helpers remain usable in the isolated VM
local ESC, null = "\27", lush.null
local function fail(name, message) error("theme." .. name .. ": " .. message, 3) end
local function finite(value) return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge end
local function array(value)
    if type(value) ~= "table" or value == null then return false end
    for i = 1, #value do if rawget(value, i) == nil then return false end end
    for key in next, value do if math.type(key) ~= "integer" or key < 1 or key > #value then return false end end
    return true
end
local function color(value, name)
    if value == nil or value == false or value == "transparent" then return nil end
    if type(value) ~= "string" then fail(name, "color must be #RGB or #RRGGBB") end
    local rgb = value:match("^#(%x%x%x)$")
    if rgb then return "#" .. rgb:sub(1, 1):rep(2) .. rgb:sub(2, 2):rep(2) .. rgb:sub(3, 3):rep(2) end
    if value:match("^#%x%x%x%x%x%x$") then return value end
    fail(name, "color must be #RGB or #RRGGBB")
end
local function style(value, name)
    if value == nil then return {} end
    if type(value) ~= "table" then fail(name, "style must be a table") end
    local result = {}
    for key, item in next, value do result[key] = item end
    for _, key in ipairs{"fg", "bg", "success_fg", "error_fg", "success_bg", "error_bg", "dirty_fg",
        "dirty_bg", "ahead_fg", "ahead_bg", "behind_fg", "behind_bg", "diverged_fg", "diverged_bg"} do
        result[key] = color(value[key], name)
    end
    for _, key in ipairs{"prefix", "suffix", "ascii", "success_text", "error_text", "mode", "label"} do
        if result[key] ~= nil and type(result[key]) ~= "string" then fail(name, key .. " must be a string") end
    end
    for _, key in ipairs{"bold", "dim", "underline", "user_only", "show_code", "show_counts", "always", "home_shorten"} do
        if result[key] ~= nil and type(result[key]) ~= "boolean" then fail(name, key .. " must be a boolean") end
    end
    if result.icon ~= nil and type(result.icon) ~= "boolean" and type(result.icon) ~= "string" then
        fail(name, "icon must be a boolean or string")
    end
    if result.mode ~= nil and result.mode ~= "full" and result.mode ~= "folder" then fail(name, "mode must be full or folder") end
    for _, key in ipairs{"threshold_ms", "branch_limit"} do
        if result[key] ~= nil and (not finite(result[key]) or result[key] < 0) then fail(name, key .. " must be nonnegative") end
    end
    return result
end
local component_kinds = {text = true, os = true, path = true, git = true, session = true, time = true,
    status = true, execution_time = true, python = true, battery = true, root = true, memory = true, chain = true}
local function components(value, name)
    if value == nil then return {} end
    if not array(value) then fail(name, "components must be an array") end
    local result = {}
    for index, item in ipairs(value) do
        if type(item) == "string" then item = theme.text(item) end
        if type(item) ~= "table" or not component_kinds[item.kind] then fail(name, "expected a theme component") end
        result[index] = item
    end
    return result
end
function theme.text(value, options)
    if type(value) ~= "string" and not finite(value) then fail("text", "value must be text or a finite number") end
    return {kind = "text", value = tostring(value), style = style(options, "text")}
end
for _, name in ipairs{"os", "path", "git", "session", "time", "status", "execution_time", "python", "battery", "root", "memory"} do
    theme[name] = function(options) return {kind = name, style = style(options, name)} end
end
function theme.separator(value, options) return theme.text(value or "", options) end
function theme.chain(values, options)
    options = options or {}
    if type(options) ~= "table" then fail("chain", "options must be a table") end
    local side = options.side or "left"
    if side ~= "left" and side ~= "right" then fail("chain", "side must be left or right") end
    for _, key in ipairs{"leading", "trailing"} do
        if options[key] ~= nil and type(options[key]) ~= "boolean" then fail("chain", key .. " must be a boolean") end
    end
    for _, key in ipairs{"separator", "ascii_separator"} do
        if options[key] ~= nil and type(options[key]) ~= "string" then fail("chain", key .. " must be a string") end
    end
    local children = components(values, "chain")
    for _, child in ipairs(children) do if child.kind == "chain" then fail("chain", "chains cannot contain another chain") end end
    return {kind = "chain", components = children, side = side,
        leading = options.leading == true, trailing = options.trailing ~= false,
        separator = options.separator, ascii_separator = options.ascii_separator}
end
function theme.row(value)
    if type(value) ~= "table" then fail("row", "options must be a table") end
    return {kind = "row", left = components(value.left, "row"), right = components(value.right, "row")}
end
function theme.prompt(value)
    if type(value) ~= "table" then fail("prompt", "options must be a table") end
    local rows = value.rows or {}
    if not array(rows) or #rows > 4 then fail("prompt", "rows must be an array of at most four rows") end
    local copy = {}
    for index, row in ipairs(rows) do
        if type(row) ~= "table" or row.kind ~= "row" then fail("prompt", "expected theme.row entries") end
        copy[index] = row
    end
    return {kind = "prompt", rows = copy, input = components(value.input, "prompt")}
end

-- Strip complete escape/control sequences rather than allowing dynamic
-- branch names, filenames or environment variables to control the terminal.
function theme.sanitize(value)
    if value == nil then return "" end
    if type(value) ~= "string" then
        if type(value) == "boolean" or finite(value) then value = tostring(value) else return "" end
    end
    local out, at = {}, 1
    while at <= #value do
        local byte = value:byte(at)
        if byte == 27 then
            local next_byte = value:byte(at + 1)
            at = at + 2
            if next_byte == 91 then
                while at <= #value do
                    local current = value:byte(at); at = at + 1
                    if current >= 64 and current <= 126 then break end
                end
            elseif next_byte == 93 or next_byte == 80 or next_byte == 88 or next_byte == 94 or next_byte == 95 then
                while at <= #value do
                    if value:byte(at) == 7 then at = at + 1; break end
                    if value:byte(at) == 27 and value:byte(at + 1) == 92 then at = at + 2; break end
                    at = at + 1
                end
            end
        elseif byte < 32 or byte == 127 then
            if byte == 9 or byte == 10 or byte == 13 then out[#out + 1] = " " end
            at = at + 1
        elseif byte < 128 then out[#out + 1] = value:sub(at, at); at = at + 1
        else
            local width = byte >= 240 and byte <= 244 and 4 or byte >= 224 and byte <= 239 and 3 or
                byte >= 194 and byte <= 223 and 2 or 1
            local ok, code = pcall(utf8.codepoint, value, at, at + width - 1)
            if ok and code and code <= 0x10ffff and width > 1 then
                if code == 0x2028 or code == 0x2029 then out[#out + 1] = " "
                elseif code < 128 or code > 159 then out[#out + 1] = value:sub(at, at + width - 1) end
                at = at + width
            else out[#out + 1] = "�"; at = at + 1 end
        end
    end
    return table.concat(out)
end
local clean = theme.sanitize
local function shorten_path(context, folder, shorten)
    local directory = clean(context.cwd or "?")
    local home = clean(context.home or ""):gsub("[/\\]+$", "")
    if shorten ~= false and home ~= "" then
        local compare, prefix = directory, home
        if context.platform == "windows" then compare, prefix = compare:lower(), prefix:lower() end
        if compare:sub(1, #prefix) == prefix and
            (#compare == #prefix or compare:sub(#prefix + 1, #prefix + 1):match("[/\\]")) then
            directory = "~" .. directory:sub(#home + 1)
        end
    end
    if folder then
        local trimmed = directory:gsub("[/\\]+$", "")
        directory = trimmed:match("([^/\\]+)$") or directory
    end
    return directory
end
local function amount(value)
    if finite(value) and value > 0 then return math.floor(value) end
    return value == true and 1 or 0
end
local function clipped(text, limit)
    if not limit then return text end
    limit = math.floor(limit)
    if limit == 0 then return "" end
    local count = utf8.len(text)
    if count and count > limit then return text:sub(1, (utf8.offset(text, limit + 1) or #text + 1) - 1) end
    return text
end
local default_options = {icons = true, os = true, path = true, git = true, session = true, time = true,
    status = true, execution_time = true, python = true, battery = true, root = true, memory = true}
local function options(value)
    if value == nil then value = {} end
    if type(value) ~= "table" then fail("render", "options must be a table") end
    local result = {}
    for key, fallback in pairs(default_options) do
        if value[key] ~= nil and type(value[key]) ~= "boolean" then fail("render", key .. " option must be a boolean") end
        result[key] = value[key] == nil and fallback or value[key]
    end
    return result
end
local function icon(style_value, opts, glyph, fallback)
    if style_value.icon == false then return "" end
    if not opts.icons then return fallback or "" end
    return type(style_value.icon) == "string" and clean(style_value.icon) or glyph
end
local function status_code(context)
    if finite(context.last_status) then return context.last_status end
    return finite(lush.last_status) and lush.last_status or 0
end
local function effective_style(original, context, component)
    local result = {}
    for key, value in pairs(original) do result[key] = value end
    if component == "status" then
        local failed = status_code(context) ~= 0
        if failed then result.fg, result.bg = result.error_fg or result.fg, result.error_bg or result.bg
        else result.fg, result.bg = result.success_fg or result.fg, result.success_bg or result.bg end
    elseif component == "git" and type(context.git) == "table" then
        local git = context.git
        local state = amount(git.ahead) > 0 and amount(git.behind) > 0 and "diverged" or
            amount(git.dirty) + amount(git.staged) > 0 and "dirty" or
            amount(git.ahead) > 0 and "ahead" or amount(git.behind) > 0 and "behind"
        if state then result.fg, result.bg = result[state .. "_fg"] or result.fg, result[state .. "_bg"] or result.bg end
    end
    return result
end
local function resolve(component, context, opts)
    local name, original = component.kind, component.style or {}
    if name ~= "text" and opts[name] == false then return "", original end
    local value = ""
    if name == "text" then value = not opts.icons and original.ascii or component.value
    elseif name == "path" then
        value = shorten_path(context, original.mode == "folder", original.home_shorten)
        if original.icon then value = icon(original, opts, " ", "") .. value end
    elseif name == "os" then
        local platform = context.platform or "unix"
        local label = original.label or (platform == "windows" and "Windows" or platform == "macos" and "macOS" or "Linux")
        value = opts.icons and original.icon ~= false and icon(original, opts,
            platform == "windows" and "" or platform == "macos" and "" or "", label) or label
    elseif name == "session" then
        local user, host = clean(context.user), clean(context.host)
        value = original.user_only and user or user ~= "" and host ~= "" and user .. "@" .. host or user .. host
    elseif name == "time" then
        value = clean(context.time)
        if value ~= "" and original.icon then value = icon(original, opts, " ", "") .. value end
    elseif name == "root" then
        if context.is_admin then value = original.icon == false and (original.label or "admin") or icon(original, opts, "⚡", original.label or "admin") end
    elseif name == "status" then
        local code = status_code(context)
        if code ~= 0 or original.always ~= false then
            value = code ~= 0 and original.error_text or original.success_text
            value = value or (opts.icons and "❯" or ">")
            if not opts.icons and original.ascii then value = original.ascii end
            if original.show_code and code ~= 0 then value = value .. " " .. tostring(code) end
        end
    elseif name == "git" and type(context.git) == "table" and context.git.branch then
        local git = context.git
        value = clipped(clean(git.branch), original.branch_limit)
        if value ~= "" then
            value = icon(original, opts, " ", "git:") .. value
            if original.show_counts ~= false then
                for _, item in ipairs{{"dirty", "*"}, {"staged", "+"}, {"ahead", opts.icons and "↑" or "^"},
                    {"behind", opts.icons and "↓" or "v"}, {"stash", opts.icons and "≡" or "stash:"}} do
                    local count = amount(git[item[1]])
                    if count > 0 then value = value .. " " .. item[2] .. tostring(count) end
                end
            end
        end
    elseif name == "execution_time" and finite(context.execution_ms) and context.execution_ms >= (original.threshold_ms or 150) then
        local ms = math.max(0, context.execution_ms)
        value = ms < 1000 and string.format("%.0fms", ms) or string.format("%.2fs", ms / 1000)
        if original.icon then value = icon(original, opts, "⌛ ", "") .. value end
    elseif name == "python" and type(context.python_env) == "string" and context.python_env ~= "" then
        value = icon(original, opts, " ", "py:") .. clean(context.python_env)
    elseif name == "battery" then
        local battery = context.battery
        local percent = type(battery) == "table" and battery.percent or battery
        if finite(percent) then
            value = icon(original, opts, type(battery) == "table" and battery.charging and " " or " ",
                type(battery) == "table" and battery.charging and "charge:" or "bat:") ..
                string.format("%.0f%%", math.max(0, math.min(100, percent)))
        end
    elseif name == "memory" then
        local memory = context.memory
        if type(memory) == "table" and finite(memory.used) and finite(memory.total) and memory.total > 0 then
            value = string.format("RAM: %.1f/%.1fGB", memory.used / 1073741824, memory.total / 1073741824)
        elseif type(memory) == "string" then value = "RAM: " .. clean(memory) end
    end
    value = clean(value)
    if value == "" then return "", original end
    return clean(original.prefix or "") .. value .. clean(original.suffix or ""), effective_style(original, context, name)
end
local function rgb_code(value, prefix)
    if not value then return nil end
    value = color(value, "render")
    if not value then return nil end
    return string.format("%d;2;%d;%d;%d", prefix, tonumber(value:sub(2, 3), 16), tonumber(value:sub(4, 5), 16), tonumber(value:sub(6, 7), 16))
end
local function paint(value, appearance)
    if value == "" then return "" end
    local codes = {}
    if appearance.bold then codes[#codes + 1] = "1" end
    if appearance.dim then codes[#codes + 1] = "2" end
    if appearance.underline then codes[#codes + 1] = "4" end
    local fg, bg = rgb_code(appearance.fg, 38), rgb_code(appearance.bg, 48)
    if fg then codes[#codes + 1] = fg end
    if bg then codes[#codes + 1] = bg end
    if #codes == 0 then return value end
    return ESC .. "[" .. table.concat(codes, ";") .. "m" .. value .. ESC .. "[0m"
end
local function render_chain(component, context, opts)
    local active = {}
    for _, child in ipairs(component.components) do
        local value, appearance = resolve(child, context, opts)
        if value ~= "" then active[#active + 1] = {value = value, style = appearance} end
    end
    local result = {}
    local glyph = opts.icons and (component.separator or (component.side == "right" and "" or "")) or
        (component.ascii_separator or (component.side == "right" and "<" or ">"))
    glyph = clean(glyph)
    for index, item in ipairs(active) do
        if component.side == "right" and (index > 1 or component.leading) then
            local previous = active[index - 1]
            result[#result + 1] = paint(glyph, {fg = item.style.bg, bg = previous and previous.style.bg})
        elseif component.side == "left" and index == 1 and component.leading then
            result[#result + 1] = paint(glyph, {fg = item.style.bg})
        end
        result[#result + 1] = paint(item.value, item.style)
        if component.side == "left" and (index < #active or component.trailing) then
            local following = active[index + 1]
            result[#result + 1] = paint(glyph, {fg = item.style.bg, bg = following and following.style.bg})
        end
    end
    return table.concat(result)
end
function theme.render_components(values, context, render_options)
    if type(context) ~= "table" then fail("render", "context must be a table") end
    if render_options == nil then render_options = context.options or lush.config.theme_options end
    local result, opts = {}, options(render_options)
    for _, component in ipairs(components(values, "render")) do
        if component.kind == "chain" then result[#result + 1] = render_chain(component, context, opts)
        else
            local value, appearance = resolve(component, context, opts)
            result[#result + 1] = paint(value, appearance)
        end
    end
    return table.concat(result)
end
function theme.render(specification, context, render_options)
    if type(context) ~= "table" then fail("render", "context must be a table") end
    if type(specification) ~= "table" or specification.kind ~= "prompt" then fail("render", "expected a prompt descriptor") end
    if render_options == nil then render_options = context.options or lush.config.theme_options end
    local rows, result = specification.rows or {}, {lines = {}}
    if not array(rows) or #rows > 4 then fail("render", "at most four rows are supported") end
    for index, row in ipairs(rows) do
        if row.kind ~= "row" then fail("render", "expected row descriptors") end
        result.lines[index] = {left = theme.render_components(row.left, context, render_options),
            right = theme.render_components(row.right, context, render_options)}
    end
    result.input = theme.render_components(specification.input, context, render_options)
    return result
end

-- Names select one ordinary Lua file. This intentionally does not enumerate
-- the directory or load files for themes that have not been selected.
local loaded_files = {}
local function load_message(message)
    local kind = type(message)
    if kind == "string" or kind == "number" then return tostring(message) end
    return "Lua raised a " .. kind .. " error"
end
local function theme_name(name)
    if type(name) ~= "string" or name == "" then return nil, "name must be a nonempty basename stem" end
    if name == "." or name == ".." or name:find("[/\\:]") or name:find("[%z\1-\31\127]") then
        return nil, "name must be a basename stem without separators, colon, or control characters"
    end
    if not utf8.len(name) then return nil, "name must contain valid UTF-8" end
    for _, code in utf8.codes(name) do
        if code >= 128 and code <= 159 then return nil, "name cannot contain control characters" end
    end
    -- Win32 device names retain their meaning even when an extension is added.
    if native.platform == "windows" then
        local base = name:match("^[^.]*"):upper():gsub(" +$", "")
        if base == "CON" or base == "PRN" or base == "AUX" or base == "NUL" or
            base == "CONIN$" or base == "CONOUT$" or base:match("^COM[1-9]$") or base:match("^LPT[1-9]$") then
            return nil, "name cannot be a Windows device name"
        end
    end
    return name
end
function theme.load(name)
    local accepted, message = theme_name(name)
    if not accepted then return nil, "theme.load: " .. message end
    local directory = lush.config_dir
    if type(directory) ~= "string" or directory == "" or directory:find("\0", 1, true) then
        return nil, "theme.load: lush.config_dir is unavailable"
    end
    local files = loaded_files[directory]
    if not files then files = {}; loaded_files[directory] = files end
    local cached = files[name]
    if cached then
        if cached.loading then return nil, "theme.load: recursive load of " .. string.format("%q", name) end
        return cached.value, cached.message
    end
    cached = {loading = true}
    files[name] = cached
    local filename
    local ok, value = pcall(function()
        local detail
        filename, detail = theme_path("join", directory, "themes", name .. ".lua")
        if filename == nil then error(detail or "cannot construct the theme path", 0) end
        local contents
        contents, detail = read_theme_file(filename)
        if contents == nil then error(detail or "cannot read the theme file", 0) end
        if contents:sub(1, 3) == "\239\187\191" then contents = contents:sub(4) end
        if contents:sub(1, 2) == "#!" then contents = contents:match("\n.*") or "" end
        if type(compile_theme) ~= "function" then error("theme sandbox is unavailable", 0) end
        local result
        result, detail = compile_theme(contents, filename)
        if result == nil then error(detail or "theme sandbox could not load the file", 0) end
        if type(result) ~= "function" and (type(result) ~= "table" or rawget(result, "kind") ~= "prompt") then
            error("theme file must return a prompt descriptor or builder function", 0)
        end
        return result
    end)
    cached.loading = false
    if ok then cached.value = value
    else cached.message = "theme.load: " .. (filename and filename .. ": " or "") .. load_message(value) end
    return cached.value, cached.message
end
