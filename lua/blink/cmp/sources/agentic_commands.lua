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
local FILE_PICKER_ACTION = "agentic_open_file_picker"

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
--- @return string
local function get_current_word(context)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local text_to_cursor = context.line:sub(1, cursor_col)
    return text_to_cursor:match("%S*$") or ""
end

--- @param context blink.cmp.AgenticCommands.Context
--- @return integer word_start
local function get_word_start(context)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    local current_word = get_current_word(context)
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
    local slash_char = get_word_start(context)
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

--- @param context blink.cmp.AgenticCommands.Context
--- @return blink.cmp.AgenticCommands.CompletionResponse
local function build_file_response(context)
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_col = context.cursor[2]
    --- @diagnostic disable-next-line: need-check-nil
    local cursor_row = context.cursor[1] - 1
    local at_char = get_word_start(context)
    local range = {
        start = { line = cursor_row, character = at_char },
        ["end"] = { line = cursor_row, character = cursor_col },
    }

    local item = {
        label = "file",
        kind = Kind.Event,
        insertText = "file",
        textEdit = {
            range = range,
            newText = "",
        },
        data = {
            action = FILE_PICKER_ACTION,
        },
        labelDetails = {
            description = "Open file picker",
        },
        documentation = {
            value = "Open fzf-lua file picker and attach selections",
            kind = "plaintext",
        },
    }

    --- @type blink.cmp.AgenticCommands.CompletionResponse
    local response = {
        is_incomplete_forward = false,
        is_incomplete_backward = false,
        items = { item },
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
    return { "/", "@" }
end

--- @param context blink.cmp.AgenticCommands.Context
--- @return boolean
local function is_slash_context(context)
    local current_word = get_current_word(context)
    if current_word:sub(1, 1) ~= "/" then
        return false
    end

    local has_subpath = current_word:find("/", 2, true) ~= nil
    if has_subpath then
        return false
    end

    return true
end

--- @param context blink.cmp.AgenticCommands.Context
--- @return boolean
local function is_file_context(context)
    local current_word = get_current_word(context)
    return current_word:sub(1, 1) == "@"
end

--- @param bufnr integer
--- @return blink.cmp.AgenticCommands.Context|nil
local function get_live_context(bufnr)
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return nil
    end

    local mode = vim.api.nvim_get_mode().mode
    if mode ~= "i" and mode ~= "ic" then
        return nil
    end

    if vim.api.nvim_get_current_buf() ~= bufnr then
        return nil
    end

    if vim.bo[bufnr].filetype ~= "AgenticInput" then
        return nil
    end

    --- @type blink.cmp.AgenticCommands.Context
    local context = {
        bufnr = bufnr,
        cursor = vim.api.nvim_win_get_cursor(0),
        line = vim.api.nvim_get_current_line(),
    }

    if not is_slash_context(context) then
        return nil
    end

    return context
end

--- Only show items when the cursor is within a slash command (at start or after whitespace)
--- @param context blink.cmp.AgenticCommands.Context
--- @param _items table[]
--- @return boolean
function Source:should_show_items(context, _items)
    local _ = self
    return is_slash_context(context) or is_file_context(context)
end

--- Return slash command completions from shared state
--- @param context blink.cmp.AgenticCommands.Context
--- @param callback fun(response: blink.cmp.AgenticCommands.CompletionResponse|nil)
--- @return fun()|nil
function Source:get_completions(context, callback)
    local _ = self
    if is_file_context(context) then
        callback(build_file_response(context))
        return nil
    end

    local States = require("agentic.states")
    local bufnr = context.bufnr
    local commands = States.getSlashCommands(bufnr)

    --- @type table<string, boolean>
    local seen_words = {}
    local initial_response = build_response(context, commands, seen_words)
    local cancel_updates = function() end

    if #commands == 0 then
        initial_response.is_incomplete_forward = true
        initial_response.is_incomplete_backward = true
    end

    callback(initial_response)

    cancel_updates = States.onSlashCommandsUpdate(
        bufnr,
        function(updated_commands)
            local live_context = get_live_context(bufnr)
            if not live_context then
                cancel_updates()
                cancel_updates = function() end
                return
            end

            local update_response =
                build_response(live_context, updated_commands, seen_words)
            if #update_response.items > 0 then
                callback(update_response)
            end
        end
    )

    return function()
        cancel_updates()
        cancel_updates = function() end
    end
end

--- @param _context blink.cmp.AgenticCommands.Context
--- @param item table
--- @param callback fun()
--- @param default_implementation fun()
function Source:execute(_context, item, callback, default_implementation)
    local _ = self
    local data = item and item.data or nil
    if type(data) == "table" and data.action == FILE_PICKER_ACTION then
        local FilePicker = require("agentic.ui.file_picker")
        local SessionRegistry = require("agentic.session_registry")
        local session =
            SessionRegistry.sessions[vim.api.nvim_get_current_tabpage()]
        if session then
            default_implementation()
            FilePicker.open(function(file_path)
                local added = session.file_list:add(file_path)
                if added == true then
                    session.widget:show({
                        focus_prompt = false,
                    })
                end
            end, function()
                vim.schedule(function()
                    session.widget:focus_prompt()
                    vim.cmd("startinsert!")
                end)
            end)
        end
        callback()
        return
    end

    default_implementation()
    callback()
end

return Source
