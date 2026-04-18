--- @diagnostic disable: unresolved-require, need-check-nil, param-type-mismatch
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

--- @param context blink.cmp.AgenticCommands.Context
--- @return integer slash_char
local function get_slash_char(context)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local text_to_cursor = context.line:sub(1, cursor_col)
    local current_word = text_to_cursor:match("%S*$") or ""
    return math.floor(cursor_col - #current_word)
end

--- @param context blink.cmp.AgenticCommands.Context
--- @param commands agentic.acp.CompletionItem[]
--- @param seen_words table<string, boolean>|nil
--- @return blink.cmp.AgenticCommands.CompletionResponse
local function build_response(context, commands, seen_words)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_row = context.cursor[1] - 1
    local slash_char = get_slash_char(context)
    local range = {
        start = { line = cursor_row, character = slash_char + 1 },
        ["end"] = { line = cursor_row, character = cursor_col },
    }

    --- @type table[]
    local items = {}
    for _, cmd in ipairs(commands) do
        if not seen_words or not seen_words[cmd.word] then
            if seen_words then
                seen_words[cmd.word] = true
            end

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
    end

    --- @type blink.cmp.AgenticCommands.CompletionResponse
    local response = {
        is_incomplete_forward = false,
        is_incomplete_backward = false,
        items = items,
    }

    return response
end

--- Only enable in agentic prompt buffers
--- @return boolean
function Source:enabled()
    local _ = self
    return vim.bo.filetype == "AgenticInput"
end

--- Trigger completion when \`/\` is typed
--- @return string[]
function Source:get_trigger_characters()
    local _ = self
    return { "/" }
end

--- Only show items when the cursor is within a slash command (at start or after whitespace)
--- @param context blink.cmp.AgenticCommands.Context
--- @param _items table[]
--- @return boolean
function Source:should_show_items(context, _items)
    local _ = self
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local text_to_cursor = context.line:sub(1, cursor_col)
    local current_word = text_to_cursor:match("%S*$") or ""
    return current_word:match("^/") ~= nil
end

--- Return slash command completions from shared state
--- @param context blink.cmp.AgenticCommands.Context
--- @param callback fun(response: blink.cmp.AgenticCommands.CompletionResponse|nil)
--- @return fun()|nil
function Source:get_completions(context, callback)
    local _ = self
    local States = require("agentic.states")
    local bufnr = context.bufnr
    local commands = States.getSlashCommands(bufnr)

    --- @type table<string, boolean>
    local seen_words = {}
    local initial_response = build_response(context, commands, seen_words)

    if #commands == 0 then
        initial_response.is_incomplete_forward = true
        initial_response.is_incomplete_backward = true
    end

    callback(initial_response)

    return States.onSlashCommandsUpdate(bufnr, function(updated_commands)
        local update_response =
            build_response(context, updated_commands, seen_words)
        if #update_response.items > 0 then
            callback(update_response)
        end
    end)
end

return Source
