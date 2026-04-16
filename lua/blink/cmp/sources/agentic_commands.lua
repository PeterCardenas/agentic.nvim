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

    local States = require("agentic.states")
    States.onSlashCommandsUpdate(function(_items)
        vim.schedule(function()
            local mode = vim.api.nvim_get_mode().mode
            if mode ~= "i" and mode ~= "ic" then
                return
            end
            local bufnr = vim.api.nvim_get_current_buf()
            if vim.bo[bufnr].filetype ~= "AgenticInput" then
                return
            end
            local cursor = vim.api.nvim_win_get_cursor(0)
            local row = cursor[1]
            local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
                or ""
            if line:match("^/%S*$") or line:match("%s/%S*$") then
                local ok, blink = pcall(require, "blink.cmp")
                if ok and blink.show then
                    blink.show({ providers = { "agentic_commands" } })
                end
            end
        end)
    end)

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

--- Only show items when the cursor is within a slash command (at start or after whitespace)
--- @param context blink.cmp.AgenticCommands.Context
--- @param _items table[]
--- @return boolean
function Source:should_show_items(context, _items)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local text_to_cursor = context.line:sub(1, cursor_col)
    local current_word = text_to_cursor:match("%S*$") or ""
    return current_word:match("^/") ~= nil
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

    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local text_to_cursor = context.line:sub(1, cursor_col)
    local current_word = text_to_cursor:match("%S*$") or ""
    -- 0-indexed position of the slash; character after slash = slash_pos + 1
    local slash_char = cursor_col - #current_word

    --- @diagnostic disable-next-line: need-check-nil
    local cursor_row = context.cursor[1] - 1 -- 0-indexed line
    local range = {
        start = { line = cursor_row, character = slash_char + 1 },
        ["end"] = { line = cursor_row, character = cursor_col },
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
