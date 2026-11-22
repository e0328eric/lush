-- Shared output documentation/completion metadata. This performs no validation
-- and never calls a producer. Field arrays and nested descriptors are acyclic.
lush.schemas = lush.schemas or {}
lush.schemas.file = {
    {
        name = "name",
        type = "string",
        optional = false,
        description = "Entry name; explicit file arguments may retain the supplied path.",
    },
    {
        name = "path",
        type = "string",
        optional = false,
        description = "Filesystem path used to access this entry.",
    },
    {
        name = "type",
        type = "string",
        optional = false,
        description = "Entry kind: file, dir, symlink, fifo, socket, block, character, or other.",
    },
    {
        name = "kind",
        type = "string",
        optional = false,
        description = "Alias of type, with the same entry-kind string.",
    },
    {
        name = "size",
        type = "integer",
        optional = false,
        description = "Size in bytes; --total-size sums directory contents.",
    },
    {
        name = "depth",
        type = "integer",
        optional = false,
        description = "Recursion depth: 0 for top-level records, increasing for descendants.",
    },
    {
        name = "modified",
        type = "integer",
        optional = true,
        description = "Modification time in Unix seconds, when the filesystem supplies it.",
    },
    {
        name = "git",
        type = "string",
        optional = true,
        description = "Two-character fls Git status with --git when repository metadata is available.",
    },
    {
        name = "git_x",
        type = "integer",
        optional = true,
        description = "Byte code of the first (index/staged) character in git; available with git.",
    },
    {
        name = "git_y",
        type = "integer",
        optional = true,
        description = "Byte code of the second (working-tree) character in git; available with git.",
    },
    {
        name = "link_target",
        type = "string",
        optional = true,
        description = "Symbolic-link target, when the target text can be read.",
    },
}

local schemas = lush.schemas
local function field(name, kind, description, optional, nested)
    local result = nested or {}
    result.name, result.type, result.description, result.optional =
        name, kind, description, optional == true
    return result
end
schemas.stat = {
    field("path", "string", "The path supplied to stat()."),
    field("name", "string", "Final path component."),
    field(
        "type",
        "string",
        "file, dir, symlink, or other; stat follows the final link by default."
    ),
    field("size", "integer", "Size in bytes reported by the filesystem."),
    field("modified", "integer", "Modification time in Unix seconds, when available.", true),
}
schemas.version = {
    field("name", "string", "Shell name: lush."),
    field("version", "string", "Lush version."),
    field("lua", "string", "Embedded Lua version, such as Lua 5.5."),
    field("platform", "string", "Native platform family: windows or unix."),
}
schemas.command = {
    field("name", "string", "Documented command or namespace name."),
    field("category", "string", "Command group, such as Filesystem or Data."),
    field("description", "string", "Short command description."),
}
schemas.alias = {
    field("name", "string", "The Lua name registered in the prompt's global environment."),
    field("kind", "string", "Alias target kind: function or external."),
    field(
        "command",
        "array",
        "Fixed executable and arguments for an external alias.",
        true,
        { items = { type = "string" } }
    ),
}
schemas.result = {
    field("ok", "boolean", "True when the command pipeline exited successfully."),
    field("code", "integer", "Pipeline exit code, using the rightmost nonzero stage status."),
    field("signal", "integer", "Terminating signal when reported; zero for a normal exit."),
    field(
        "stdout",
        "string",
        "Captured standard-output bytes; empty for inherited-terminal run()."
    ),
    field("stderr", "string", "Captured standard-error bytes; empty for inherited-terminal run()."),
    field(
        "statuses",
        "array",
        "Exit codes in pipeline-stage order.",
        false,
        { items = { type = "integer" } }
    ),
}
schemas.exec = {
    field(
        "commands",
        "array",
        "Ordered pipeline stages, each an argument array; no process starts on construction.",
        false,
        { items = { type = "array", items = { type = "string" } } }
    ),
    field(
        "input",
        "string",
        "Bytes supplied to the first command, when the plan has explicit input.",
        true
    ),
}
schemas.enumerated = {
    field("index", "integer", "Item index, beginning at the requested start (default zero)."),
    field(
        "item",
        "any",
        "Original input item; its type and fields are data-dependent.",
        false,
        { data_dependent = true }
    ),
}

-- Constructors copy user options. These known style fields are documented,
-- while arbitrary additional user keys remain data-dependent.
schemas.theme_style = {}
for _, name in ipairs({
    "fg",
    "bg",
    "success_fg",
    "success_bg",
    "error_fg",
    "error_bg",
    "dirty_fg",
    "dirty_bg",
    "ahead_fg",
    "ahead_bg",
    "behind_fg",
    "behind_bg",
    "diverged_fg",
    "diverged_bg",
}) do
    schemas.theme_style[#schemas.theme_style + 1] =
        field(name, "string", "Optional normalized #RRGGBB color.", true)
end
for _, name in ipairs({ "prefix", "suffix", "ascii", "success_text", "error_text", "mode", "label" }) do
    schemas.theme_style[#schemas.theme_style + 1] =
        field(name, "string", "Optional component text or display setting.", true)
end
for _, name in ipairs({
    "bold",
    "dim",
    "underline",
    "user_only",
    "show_code",
    "show_counts",
    "always",
    "home_shorten",
}) do
    schemas.theme_style[#schemas.theme_style + 1] =
        field(name, "boolean", "Optional component formatting switch.", true)
end
schemas.theme_style[#schemas.theme_style + 1] =
    field("icon", "string|boolean", "Optional replacement icon or visibility switch.", true)
for _, name in ipairs({ "threshold_ms", "branch_limit" }) do
    schemas.theme_style[#schemas.theme_style + 1] =
        field(name, "number", "Optional nonnegative component threshold or limit.", true)
end
local function style_field(optional)
    return field(
        "style",
        "record",
        "Copied style/options; extra user-provided keys are data-dependent.",
        optional,
        { fields = schemas.theme_style, data_dependent = true }
    )
end
schemas.theme_basic = {
    field("kind", "string", "Component kind, such as path, git, time, or status."),
    style_field(false),
}
schemas.theme_text = {
    field("kind", "string", "Descriptor kind: text."),
    field("value", "string", "Literal component text; numeric input is converted to text."),
    style_field(false),
}
local leaf_fields = {
    field("kind", "string", "Leaf component kind."),
    style_field(false),
    field("value", "string", "Literal text, present for text/separator components.", true),
}
schemas.theme_chain = {
    field("kind", "string", "Descriptor kind: chain."),
    field(
        "components",
        "array",
        "Normalized non-chain child components.",
        false,
        { items = { type = "record", fields = leaf_fields } }
    ),
    field("side", "string", "Join direction: left or right."),
    field("leading", "boolean", "Whether to include the leading edge separator."),
    field("trailing", "boolean", "Whether to include the trailing edge separator."),
    field("separator", "string", "Custom powerline separator when supplied.", true),
    field("ascii_separator", "string", "Custom ASCII separator when supplied.", true),
}
-- A union of the possible child descriptor fields, with no recursive cycle.
schemas.theme_component = {
    field("kind", "string", "Component kind; determines which other fields are present."),
    style_field(true),
    field("value", "string", "Literal text for a text/separator component.", true),
    field(
        "components",
        "array",
        "Child components for a chain.",
        true,
        { items = { type = "record", fields = leaf_fields } }
    ),
    field("side", "string", "Join direction for a chain.", true),
    field("leading", "boolean", "Leading-edge setting for a chain.", true),
    field("trailing", "boolean", "Trailing-edge setting for a chain.", true),
    field("separator", "string", "Custom chain separator.", true),
    field("ascii_separator", "string", "Custom ASCII chain separator.", true),
}
schemas.theme_row = {
    field("kind", "string", "Descriptor kind: row."),
    field(
        "left",
        "array",
        "Normalized left-side components.",
        false,
        { items = { type = "record", fields = schemas.theme_component } }
    ),
    field(
        "right",
        "array",
        "Normalized right-side components.",
        false,
        { items = { type = "record", fields = schemas.theme_component } }
    ),
}
schemas.theme_prompt = {
    field("kind", "string", "Descriptor kind: prompt."),
    field(
        "rows",
        "array",
        "Up to four header-row descriptors.",
        false,
        { items = { type = "record", fields = schemas.theme_row } }
    ),
    field(
        "input",
        "array",
        "Normalized components before editable input.",
        false,
        { items = { type = "record", fields = schemas.theme_component } }
    ),
}
schemas.rendered_prompt = {
    field(
        "lines",
        "array",
        "Rendered header lines, in display order.",
        false,
        {
            items = {
                type = "record",
                fields = {
                    field("left", "string", "Left-side text with validated SGR styling."),
                    field("right", "string", "Right-side text with validated SGR styling."),
                },
            },
        }
    ),
    field("input", "string", "Styled prefix drawn immediately before editable Lua input."),
}

local function record(fields)
    return { type = "record", fields = fields }
end
local function stream(fields)
    return { type = "stream", items = record(fields) }
end
schemas.producers = {
    ls = stream(schemas.file),
    stat = record(schemas.stat),
    version = record(schemas.version),
    commands = stream(schemas.command),
    aliases = { type = "array", items = record(schemas.alias) },
    ["help.commands"] = stream(schemas.command),
    ["help.find"] = stream(schemas.command),
    run = record(schemas.result),
    capture = record(schemas.result),
    ["Exec.run"] = record(schemas.result),
    ["Exec.capture"] = record(schemas.result),
    ["Result.check"] = record(schemas.result),
    cmd = record(schemas.exec),
    enumerate = stream(schemas.enumerated),
    ["lush.theme.text"] = record(schemas.theme_text),
    ["lush.theme.separator"] = record(schemas.theme_text),
    ["lush.theme.chain"] = record(schemas.theme_chain),
    ["lush.theme.row"] = record(schemas.theme_row),
    ["lush.theme.prompt"] = record(schemas.theme_prompt),
    ["lush.theme.render"] = record(schemas.rendered_prompt),
    ["lush.theme.load"] = {
        type = "record|function|nil",
        data_dependent = true,
        description = "Data-dependent: the selected Lua file returns a prompt descriptor or builder function; failure returns nil and an error message. Inspect a successful value or use help('lush.theme.prompt') for descriptor fields.",
    },
}
for _, name in ipairs({
    "os",
    "path",
    "git",
    "session",
    "time",
    "status",
    "execution_time",
    "python",
    "battery",
    "root",
    "memory",
}) do
    schemas.producers["lush.theme." .. name] = record(schemas.theme_basic)
end
local dependent =
    "Data-dependent: fields and item types follow the supplied input or callback. Inspect columns() and first(1) on a record stream instead of assuming fixed fields."
for _, name in ipairs({
    "stream",
    "pipe",
    "collect",
    "where",
    "filter",
    "each",
    "map",
    "select",
    "get",
    "take",
    "skip",
    "sort_by",
    "reverse",
    "uniq",
    "first",
    "last",
    "flatten",
    "append",
    "prepend",
    "reject",
    "rename",
    "update",
    "default",
}) do
    local kind = name == "collect" and "array" or name == "pipe" and "any" or "stream"
    schemas.producers[name] = {
        type = kind,
        items = kind ~= "any" and { type = "any", data_dependent = true } or nil,
        data_dependent = true,
        description = dependent,
    }
end
for _, name in ipairs({
    "source",
    "json.decode",
    "json.array",
    "json.object",
    "from.json",
    "from_json",
    "Result.from_json",
    "Exec.from_json",
}) do
    local kind = name == "json.array" and "array"
        or name == "json.object" and "record"
        or (name == "from.json" or name == "from_json" or name == "Result.from_json" or name == "Exec.from_json") and "stream"
        or "any"
    schemas.producers[name] = {
        type = kind,
        items = (kind == "stream" or kind == "array") and { type = "any" } or nil,
        data_dependent = true,
        description = "Data-dependent: Lua source or JSON input determines the returned value and its fields. Inspect the actual value; for record streams use columns() and first(1).",
    }
end
for _, name in ipairs({
    "from.lines",
    "lines",
    "from_lines",
    "Result.lines",
    "Exec.lines",
    "columns",
}) do
    schemas.producers[name] = { type = "stream", items = { type = "string" } }
end
