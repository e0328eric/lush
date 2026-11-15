-- External Lush prompt configuration, built from the public theme utilities.
-- Adapted from Oh My Posh's powerlevel10k_classic palette and layout:
-- https://github.com/JanDeDobbeleer/oh-my-posh/blob/main/themes/powerlevel10k_classic.omp.json
local t = lush.theme

return t.prompt({
    rows = {
        t.row({
            left = {
                t.chain({
                    t.os({ fg = "#26C6DA", bg = "#546E7A", prefix = " ", suffix = " " }),
                    t.root({ fg = "#26C6DA", bg = "#546E7A", prefix = " ", suffix = " " }),
                    t.path({ fg = "#26C6DA", bg = "#546E7A", prefix = " ", suffix = " " }),
                    t.git({ fg = "#D4E157", bg = "#546E7A", prefix = " ", suffix = " " }),
                }),
            },
            right = {
                t.chain(
                    {
                        t.session({ fg = "#D4E157", bg = "#546E7A", prefix = " ", suffix = " " }),
                        t.time({
                            fg = "#D4E157",
                            bg = "#546E7A",
                            icon = true,
                            prefix = " ",
                            suffix = " ",
                        }),
                    },
                    { side = "right", leading = true, trailing = false }
                ),
            },
        }),
    },
    input = { t.status({ success_fg = "#D4E157", error_fg = "#FF5252", suffix = " " }) },
})
