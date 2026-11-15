-- Run with lush examples/files.lua [directory].
local files = ls(arg[1] or ".")
    :where(function(file) return file.type == "file" end)
    :sort_by("size", true)
    :select("name", "size")

show(files)
