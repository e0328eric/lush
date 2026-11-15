-- External Lush prompt configuration, built from the public theme utilities.
-- Adapted from Oh My Posh's easy-term palette and layout:
-- https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/easy-term.omp.json
local t = lush.theme

return t.prompt({
    rows = {
        t.row({
            left = {
                t.text("╭─", { fg = "#0c7bbb", ascii = "+-" }),
                t.chain(
                    {
                        t.os({ fg = "#ffffff", bg = "#0c7bbb", prefix = " ", suffix = " " }),
                        t.text(
                            "🏠",
                            {
                                fg = "#ffffff",
                                bg = "#DA627D",
                                prefix = " ",
                                suffix = " ",
                                ascii = "home",
                            }
                        ),
                        t.path({
                            fg = "#ffffff",
                            bg = "#8a62da",
                            mode = "folder",
                            prefix = " ",
                            suffix = " ",
                        }),
                        t.git({
                            fg = "#43CCEA",
                            bg = "#191f48",
                            dirty_fg = "#FF9248",
                            diverged_fg = "#ff4500",
                            ahead_fg = "#B388FF",
                            behind_fg = "#B388FF",
                            branch_limit = 25,
                            prefix = " ",
                            suffix = " ",
                        }),
                    },
                    { leading = true }
                ),
            },
            right = {
                t.memory({ fg = "#81ff91", prefix = " | " }),
                t.python({ fg = "#81ff91", prefix = " | " }),
                t.chain(
                    {
                        t.execution_time({
                            fg = "#4b4b4b",
                            bg = "#cecece",
                            icon = true,
                            prefix = " ",
                            suffix = " ",
                        }),
                        t.time({
                            fg = "#4b4b4b",
                            bg = "#cecece",
                            icon = "⏰ ",
                            prefix = " ",
                            suffix = " ",
                        }),
                    },
                    { side = "right", leading = true, trailing = false }
                ),
            },
        }),
    },
    input = { t.text("╰─ ", { fg = "#0c7bbb", ascii = "`- " }) },
})
