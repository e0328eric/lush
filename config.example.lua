-- Lush creates get_config_dir()/lush/init.lua when it is missing and preserves
-- existing configuration. Edit that file, copy settings from this example,
-- or use lush --config config.example.lua to load this example directly.
-- Glosso supplies the platform config directory (Roaming AppData on Windows,
-- XDG_CONFIG_HOME or ~/.config on Linux). Settings are loaded at startup.
-- These themes are external Lua configuration, not built into Lush.
-- Each file returns a prompt made with the same public utility functions below.
local theme_directory = path.join(lush.config_dir or pwd(), "themes")
lush.config.themes = {
    powerlevel10k_classic = source(path.join(theme_directory, "powerlevel10k_classic.lua")),
    ["easy-term"] = source(path.join(theme_directory, "easy-term.lua")),
    iterm2 = source(path.join(theme_directory, "iterm2.lua")),
}
lush.config.theme = "powerlevel10k_classic" -- "easy-term", "iterm2", or nil for plain
lush.config.theme_options = { icons = true, git = true, time = true }
-- Use icons = false for ASCII symbols without a Nerd Font.
-- lush.config.prompt = function() return pwd() .. " > " end -- overrides theme

-- Reusable functions build rows from text, path, Git, session, clock, status,
-- timing, Python environment, battery, and memory components.
local t = lush.theme
lush.config.themes.custom = t.prompt({
    rows = {
        t.row({
            left = { t.path({ fg = "#26C6DA", suffix = " " }), t.git({ fg = "#D4E157" }) },
            right = { t.session({ fg = "#D4E157", suffix = " " }), t.time({ fg = "#26C6DA" }) },
        }),
    },
    input = { t.status({ success_fg = "#D4E157", error_fg = "#FF5252", suffix = " " }) },
})
-- lush.config.theme = "custom"

-- Persistent history defaults to get_config_dir()/lush/history.jsonl.
-- Only interactive sessions load/save it; scripts and -c do not.
-- Leave history_file unset for the default, or set an explicit path:
-- lush.config.history_file = "C:/Users/me/AppData/Roaming/lush/history.jsonl"
-- lush.config.history_file = false  -- keep in-memory history without saving
-- An empty string also disables saving. Relative paths use the startup directory.
-- An unset field permits the LUSH_HISTORY_FILE environment override.
lush.config.history_limit = 1000 -- 0..100000; bounds in-memory entries
lush.config.autosuggestions = true -- Right accepts; Enter runs only typed text
lush.config.syntax_highlighting = true -- Color Lua input at the prompt

function gst()
    return cmd.git("status", "--short")
end

function largest(path, limit)
    return ls(path)
        :where(function(file)
            return file.type == "file"
        end)
        :sort_by("size", true)
        :take(limit or 10)
        :select("name", "size")
end
