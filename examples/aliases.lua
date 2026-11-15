-- Personal aliases: ordinary trusted Lua, loaded by init.lua.
-- Call aliases using Lua syntax: v('notes.txt'), l(), vimconfig().
-- External aliases return lazy command plans, like cmd.nvim(...).
-- Use run(v('notes.txt')) in a script; at the prompt the result runs directly.
-- Copy text with a pipeline: 'hello' | pbcopy().

alias({
    v = { "nvim" },
    h = { "hx" },
    s = ls,
    l = function(...)
        return ls("-al", ...)
    end,
    lg = { "lazygit" },
    dyt = { "yt-dlp" },
    getmusic = { "yt-dlp", "-x", "--audio-format", "m4a" },
    pbcopy = { "win32yank.exe", "-i" },
})
