--- Type stubs for blink.cmp (not in this project's LuaLS workspace)
--- @class blink.cmp.AgenticCommands.Context
--- @field cursor number[]
--- @field line string
--- @field bufnr number

--- @class blink.cmp.AgenticCommands.CompletionResponse
--- @field is_incomplete_forward boolean
--- @field is_incomplete_backward boolean
--- @field items table[]

local Kind = require("blink.cmp.types").CompletionItemKind

--- blink.cmp source for agentic.nvim slash commands
--- Provides completion for \`/command\` in the agentic prompt buffer (filetype: AgenticInput)
--- @class blink.cmp.AgenticCommandsSource
local Source = {}

--- @param _ table
--- @param _config table
--- @return blink.cmp.AgenticCommandsSource
function Source.new(_, _config)
    local self = setmetatable({}, { __index = Source })
    return self
end

--- Only enable in agentic prompt buffers
--- @return boolean
function Source:enabled()
    return vim.bo.filetype == "AgenticInput"
end

--- Trigger completion when \`/\` is typed
--- @return string[]
function Source:get_trigger_characters()
    return { "/" }
end

--- Only show items when the first line starts with \`/\` and has no spaces
--- @param context blink.cmp.AgenticCommands.Context
--- @param _items table[]
--- @return boolean
function Source:should_show_items(context, _items)
    local row = context.cursor[1]
    if row ~= 1 then
        return false
    end

    local line = context.line
    return line:match("^/") ~= nil and line:match("%s") == nil
end

--- Return slash command completions from shared state
--- @param context blink.cmp.AgenticCommands.Context
--- @param callback fun(response: blink.cmp.AgenticCommands.CompletionResponse|nil)
--- @return nil
function Source:get_completions(context, callback)
    local States = require("agentic.states")
    local commands = States.getSlashCommands()
    if #commands == 0 then
        callback()
        return nil
    end

    local cursor_col = context.cursor[2]

    local range = {
        start = { line = 0, character = 1 },
        ["end"] = { line = 0, character = cursor_col },
    }

    local items = {}
    for _, cmd in ipairs(commands) do
        local item = {
            label = "/" .. cmd.word,
            kind = Kind.Event,
            insertText = cmd.word,
            textEdit = {
                range = range,
                newText = cmd.word,
            },
            labelDetails = {
                description = cmd.menu,
            },
        }

        if cmd.info and #cmd.info > 0 then
            item.documentation = {
                value = cmd.info,
                kind = "plaintext",
            }
        end

        table.insert(items, item)
    end

    --- @type blink.cmp.AgenticCommands.CompletionResponse
    local response = {
        is_incomplete_forward = false,
        is_incomplete_backward = false,
        items = items,
    }

    callback(response)

    return nil
end

return Source
