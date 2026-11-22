-- Lush configuration. This file is created once and is yours to edit.
-- It is ordinary Lua, loaded before the prompt, scripts, and -c commands.

-- Theme definitions are editable Lua files in this config directory.
-- Each file builds a prompt with lush.theme utilities and returns it.
-- Only the selected name is loaded from themes/<name>.lua, on first use.
-- Named files/theme.load run in a restricted Lua state with basic functions
-- and pure theme utilities, without shell, filesystem, or process access.
-- File builders receive copied context/options; memory and execution are bounded.
-- Unselected files are not executed. This init.lua keeps normal shell access;
-- source() and builders defined here deliberately bypass file restrictions.
-- The shell itself contains no named theme definitions. Register an optional
-- descriptor or builder here to override a name without loading its file.
lush.config.themes = lush.config.themes or {}
lush.config.theme = nil -- Set a filename stem from the themes directory to select it.
lush.config.theme_options = { icons = true, git = true, time = true }
-- Set icons = false above for an ASCII prompt without a Nerd Font.
-- A prompt string or callback overrides the selected theme:
-- lush.config.prompt = function() return pwd() .. " > " end

-- Or build a theme directly here with the reusable utilities:
-- local t = lush.theme
-- lush.config.theme = t.prompt{
--     rows = {t.row{left = {t.path{fg = "#26C6DA"}, t.git{prefix = " "}},
--                    right = {t.time{fg = "#D4E157"}}}},
--     input = {t.status{success_fg = "#D4E157", error_fg = "#FF5252", suffix = " "}},
-- }

lush.config.history_limit = 1000
lush.config.autosuggestions = true -- Right Arrow accepts a suggestion.
lush.config.syntax_highlighting = true

-- History defaults to history.jsonl beside this file. An unset history_file
-- permits the LUSH_HISTORY_FILE environment override.
-- lush.config.history_file = false  -- Keep session history without saving.
-- lush.config.history_file = "path/to/history.jsonl"

-- Local functions become prompt commands when registered explicitly:
-- local function home() cd(path.expand('~')) end
-- alias {home = home, ll = function(...) return ls('-al', ...) end}
-- Command argument arrays create lazy external commands: alias('v', {'nvim'}).
-- Keep personal aliases in an optional, trusted aliases.lua beside this file.
if type(lush.config_dir) == "string" and lush.config_dir ~= "" then
    local aliases_file = path.join(lush.config_dir, "aliases.lua")
    if exists(aliases_file) then
        source(aliases_file)
    end
end
