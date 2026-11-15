-- External Lush prompt configuration, built from the public theme utilities.
-- Adapted from Oh My Posh's iterm2 palette and layout:
-- https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/iterm2.omp.json
local t = lush.theme

return t.prompt({
    rows = {
        t.row({
            left = {
                t.chain({
                    t.os({ fg = "#fff", bg = "#003543", prefix = " ", suffix = " " }),
                    t.session({
                        fg = "#d2ff5e",
                        bg = "#003543",
                        user_only = true,
                        prefix = " ",
                        suffix = " ",
                    }),
                    t.path({
                        fg = "#003544",
                        bg = "#0087D8",
                        icon = true,
                        prefix = " ",
                        suffix = " ",
                    }),
                    t.git({
                        fg = "#193549",
                        bg = "#d2ff5e",
                        dirty_bg = "#ff9248",
                        diverged_bg = "#f26d50",
                        ahead_bg = "#89d1dc",
                        behind_bg = "#f17c37",
                        prefix = " ",
                        suffix = " ",
                    }),
                    t.status({
                        fg = "#242424",
                        success_bg = "#33DD2D",
                        error_bg = "#f1184c",
                        success_text = "✓",
                        error_text = "✗",
                        ascii = "status",
                        show_code = true,
                        prefix = " ",
                        suffix = " ",
                    }),
                }),
            },
            right = {
                t.chain(
                    {
                        t.battery({ fg = "#242424", bg = "#FFCD58", prefix = " ", suffix = " " }),
                        t.python({ fg = "#003544", bg = "#0087D8", prefix = " ", suffix = " " }),
                        t.time({
                            fg = "#fff",
                            bg = "#003543",
                            icon = " ",
                            prefix = " ",
                            suffix = " ",
                        }),
                    },
                    { side = "right", leading = true, trailing = false }
                ),
            },
        }),
    },
    input = {
        t.root({ fg = "#FFD700", suffix = " " }),
        t.text("🚀 ", { fg = "#f1184c", ascii = "> " }),
    },
})
