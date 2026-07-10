local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.CursorCommonRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string
--- @field line? number
--- @field start_line? number
--- @field end_line? number
--- @field offset? number
--- @field limit? number
--- @field file_path? string
--- @field path? string
--- @field directory? string
--- @field glob? string
--- @field pattern? string
--- @field search_term? string
---
--- @class agentic.acp.CursorTaskRawInput : agentic.acp.RawInput
--- @field _toolName? string
--- @field prompt? string
--- @field description? string
--- @field subagentType? string|table
--- @field model? string
---
--- @alias agentic.acp.CursorRawInput agentic.acp.CursorCommonRawInput|agentic.acp.CursorTaskRawInput

--- @class agentic.acp.CursorToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? agentic.acp.CursorRawInput

--- Cursor sends rawOutput on tool_call_update with varying shapes per kind
--- @class agentic.acp.CursorRawOutput
--- @field content? string File contents (read kind)
--- @field stdout? string Command stdout (execute kind)
--- @field stderr? string Command stderr (execute kind)
--- @field exitCode? number Command exit code (execute kind)
--- @field totalFiles? number Number of files found (search kind)
--- @field truncated? boolean Whether search results were truncated (search kind)

--- @class agentic.acp.CursorToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawOutput? agentic.acp.CursorRawOutput
--- @field kind? agentic.acp.ToolKind
--- @field title? string
--- @field rawInput? agentic.acp.CursorRawInput

--- Cursor-specific adapter that extends ACPClient with Cursor-specific behaviors
--- @class agentic.acp.CursorACPAdapter : agentic.acp.ACPClient
--- @field _available_commands_updates table<string, table> Cursor sends available commands before session starts, indexed by session ID, to be processed after session creation
--- @field _chunk_stream_started table<string, table<string, boolean>> Track whether a chunk stream started per session and chunk type
--- @field _task_tool_inputs table<string, agentic.acp.CursorTaskRawInput> Track task raw input so completion updates can rebuild a clean task body
local CursorACPAdapter = setmetatable({}, { __index = ACPClient })
CursorACPAdapter.__index = CursorACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.CursorACPAdapter
function CursorACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, CursorACPAdapter) --[[@as agentic.acp.CursorACPAdapter]]

    -- Initialize session-indexed storage for available commands
    self._available_commands_updates = {}
    self._chunk_stream_started = {}
    self._task_tool_inputs = {}

    return self
end

--- @param value number|string|nil
--- @return integer|nil
local function to_integer(value)
    if type(value) == "number" then
        return math.floor(value)
    end

    if type(value) == "string" then
        local parsed = tonumber(value)
        if parsed then
            return math.floor(parsed)
        end
    end

    return nil
end

--- @param kind string
--- @param title string|nil
--- @return string
local function strip_title_prefix(kind, title)
    local trimmed = vim.trim(title or "")
    if trimmed == "" then
        return ""
    end

    local lowercase_kind = kind:lower()
    local lowercase_title = trimmed:lower()
    local prefix = lowercase_kind .. " "
    if vim.startswith(lowercase_title, prefix) then
        return vim.trim(trimmed:sub(#prefix + 1))
    end

    return trimmed
end

--- @param value string|nil
--- @return string
local function strip_wrapping_backticks(value)
    local trimmed = vim.trim(value or "")
    return trimmed:match("^`(.+)`$") or trimmed
end

--- @param raw_input agentic.acp.CursorRawInput|nil
--- @return integer|nil start_line
--- @return integer|nil end_line
local function resolve_line_range(raw_input)
    if not raw_input or vim.tbl_isempty(raw_input) then
        return nil, nil
    end

    local start_line = to_integer(raw_input.line)
        or to_integer(raw_input.start_line)
    if not start_line then
        local offset = to_integer(raw_input.offset)
        if offset and offset >= 0 then
            start_line = offset + 1
        end
    end

    local end_line = to_integer(raw_input.end_line)
    if start_line and not end_line then
        local limit = to_integer(raw_input.limit)
        if limit and limit > 0 then
            end_line = start_line + limit - 1
        end
    end

    return start_line, end_line
end

--- @param path string|nil
--- @return string
local function to_display_path(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end

    return FileSystem.to_smart_path(path)
end

--- @param path string|nil
--- @return string
local function to_search_display_path(path)
    if type(path) ~= "string" or path == "" then
        return ""
    end

    local smart_path = FileSystem.to_smart_path(path)
    local cwd = vim.uv.cwd()
    if type(cwd) == "string" and cwd ~= "" then
        local absolute_path = vim.fn.fnamemodify(path, ":p")
        local absolute_cwd = vim.fn.fnamemodify(cwd, ":p")
        if absolute_path == absolute_cwd then
            return "."
        end
    end

    return smart_path
end

--- @param kind string
--- @param raw_input agentic.acp.CursorRawInput|nil
--- @param title string|nil
--- @return string
local function format_file_argument(kind, raw_input, title)
    local fallback = strip_wrapping_backticks(strip_title_prefix(kind, title))
    if not raw_input or vim.tbl_isempty(raw_input) then
        return fallback
    end

    local base_path = to_display_path(raw_input.file_path or raw_input.path)
    if base_path == "" then
        base_path = fallback
    end
    if base_path == "" then
        return fallback
    end

    local start_line, end_line = resolve_line_range(raw_input)
    if start_line and start_line > 0 then
        if end_line and end_line >= start_line then
            return string.format("%s:%d-%d", base_path, start_line, end_line)
        end
        return string.format("%s:%d", base_path, start_line)
    end

    return base_path
end

--- @param raw_input agentic.acp.CursorRawInput|nil
--- @param title string|nil
--- @return string
function CursorACPAdapter:_format_read_argument(raw_input, title)
    return format_file_argument("read", raw_input, title)
end

--- @param raw_input agentic.acp.CursorRawInput|nil
--- @param title string|nil
--- @return string
function CursorACPAdapter:_format_search_argument(raw_input, title)
    local fallback =
        strip_wrapping_backticks(strip_title_prefix("search", title))
    if not raw_input or vim.tbl_isempty(raw_input) then
        return fallback
    end

    local query = raw_input.query
        or raw_input.pattern
        or raw_input.search_term
        or ""
    local path = raw_input.path or raw_input.file_path or raw_input.directory
    local glob = raw_input.glob

    --- @type string[]
    local parts = {}
    if type(query) == "string" and query ~= "" then
        table.insert(parts, query)
    end
    local search_path = to_search_display_path(path)
    if search_path ~= "" then
        table.insert(parts, "path=" .. search_path)
    end
    if type(glob) == "string" and glob ~= "" then
        table.insert(parts, "glob=" .. glob)
    end

    if #parts > 0 then
        return table.concat(parts, " ")
    end

    return fallback
end

--- @param raw_input agentic.acp.CursorRawInput
--- @return agentic.ui.MessageWriter.ToolCallDiff|nil diff
function CursorACPAdapter:_build_edit_diff(raw_input)
    local new_string = raw_input.content or raw_input.new_string
    local old_string = raw_input.old_string
    if new_string == nil and old_string == nil then
        return nil
    end

    --- @type agentic.ui.MessageWriter.ToolCallDiff
    local diff = {
        new = self:safe_split(new_string),
        old = self:safe_split(old_string),
        all = raw_input.replace_all or false,
    }
    return diff
end

--- @param lines string[]
--- @param label string
--- @param section string[]|nil
local function append_labeled_section(lines, label, section)
    if not section or #section == 0 then
        return
    end

    if #lines > 0 then
        table.insert(lines, "")
    end

    table.insert(lines, label)
    vim.list_extend(lines, section)
end

--- @param task agentic.acp.CursorTaskRawInput|agentic.acp.CursorTaskParams|nil
--- @param opts? { final_message?: string|nil, include_prompt?: boolean }
--- @return string[]|nil
function CursorACPAdapter:_build_task_body(task, opts)
    if not task or vim.tbl_isempty(task) then
        return nil
    end

    opts = opts or {}

    local lines = {}
    local prompt = task.prompt
    local final_message = vim.trim(opts.final_message or "")

    if
        type(prompt) == "string"
        and prompt ~= ""
        and opts.include_prompt ~= false
    then
        append_labeled_section(lines, "Prompt:", self:safe_split(prompt))
    end

    if final_message ~= "" then
        append_labeled_section(
            lines,
            "Final message:",
            self:safe_split(final_message)
        )
    end

    if #lines == 0 then
        return nil
    end

    return lines
end

--- @param task table|nil
--- @return string|nil
local function extract_task_final_message(task)
    if type(task) ~= "table" then
        return nil
    end

    local final_message = task.finalMessage
    if type(final_message) ~= "string" or vim.trim(final_message) == "" then
        return nil
    end

    return final_message
end

--- @param subagent_type string|table|nil
--- @return string|nil
local function format_subagent_type(subagent_type)
    if type(subagent_type) == "string" then
        local trimmed = vim.trim(subagent_type)
        if trimmed ~= "" and trimmed ~= "unspecified" then
            return trimmed
        end
        return nil
    end

    if type(subagent_type) ~= "table" then
        return nil
    end

    local custom = subagent_type.custom
    if type(custom) == "table" then
        for key, _ in pairs(custom) do
            if type(key) == "string" and key ~= "" and key ~= "unspecified" then
                return key
            end
        end
    end

    return nil
end

--- @param task agentic.acp.CursorTaskRawInput|agentic.acp.CursorTaskParams|nil
--- @param title string|nil
--- @return string
function CursorACPAdapter:_format_task_argument(task, title)
    local fallback = strip_title_prefix("task", title)
    if not task or vim.tbl_isempty(task) then
        return fallback ~= "" and fallback or "subagent task"
    end

    local description = vim.trim(task.description or "")
    local model = vim.trim(task.model or "")
    local subagent_type = format_subagent_type(task.subagentType)

    if model ~= "" and subagent_type and description ~= "" then
        return string.format("%s, %s: %s", model, subagent_type, description)
    end

    if model ~= "" and description ~= "" then
        return string.format("%s: %s", model, description)
    end

    if subagent_type and description ~= "" then
        return string.format("%s: %s", subagent_type, description)
    end

    if description ~= "" then
        return description
    end

    if model ~= "" and subagent_type then
        return string.format("%s, %s", model, subagent_type)
    end

    if model ~= "" then
        return model
    end

    if subagent_type then
        return subagent_type
    end

    return fallback ~= "" and fallback or "subagent task"
end

--- Overloading create_session to handle slash commands, as cursor sends them before session starts
--- @param handlers agentic.acp.ClientHandlers
--- @param callback fun(result: agentic.acp.SessionCreationResponse|nil, err: agentic.acp.ACPError|nil)
function CursorACPAdapter:create_session(handlers, callback)
    --- @param result agentic.acp.SessionCreationResponse|nil
    --- @param err agentic.acp.ACPError|nil
    local function wrapped_callback(result, err)
        callback(result, err)

        if not err and result then
            local stored_update =
                rawget(self._available_commands_updates, result.sessionId)
            if stored_update then
                Logger.debug(
                    "CursorACPAdapter",
                    "Processing stored available commands update for session "
                        .. result.sessionId
                )
                self._available_commands_updates[result.sessionId] = nil
                self:__handle_session_update(stored_update)
            end
        end
    end

    ACPClient.create_session(self, handlers, wrapped_callback)
end

--- @param params table
function CursorACPAdapter:__handle_session_update(params)
    local update = params.update
    local update_type = update.sessionUpdate
    local session_id = params.sessionId

    if update_type == "available_commands_update" then
        -- Store for later processing if session not yet subscribed
        if not self.subscribers[params.sessionId] then
            Logger.debug(
                "CursorACPAdapter",
                "Storing available commands update for session "
                    .. params.sessionId
            )
            self._available_commands_updates[params.sessionId] = params
            return
        end
    end

    -- Cursor may prefix the *first* streamed chunk with leading newlines.
    -- Normalize that only at stream start; stripping every chunk drops
    -- legitimate newline-only chunks ("\n", "\n\n"), which breaks markdown
    -- code blocks and paragraph spacing.
    if
        update_type == "agent_message_chunk"
        or update_type == "agent_thought_chunk"
    then
        local content = update.content
        local by_session = self._chunk_stream_started[session_id] or {}
        local stream_started = by_session[update_type] == true
        local stream_seen = by_session[update_type] ~= nil
        if
            content
            and content.type == "text"
            and type(content.text) == "string"
        then
            if not stream_started then
                if stream_seen then
                    if not vim.startswith(content.text, "\n") then
                        content.text = "\n\n" .. content.text
                    end
                else
                    content.text = content.text:gsub("^\n+", "")
                end
                if content.text == "" then
                    by_session[update_type] = true
                    self._chunk_stream_started[session_id] = by_session
                    return
                end
            end
        end
        by_session[update_type] = true
        self._chunk_stream_started[session_id] = by_session
    elseif session_id and rawget(self._chunk_stream_started, session_id) then
        -- Preserve whether each chunk type has streamed before so a resumed
        -- stream can be separated from the preceding text.
        for chunk_type, _ in pairs(self._chunk_stream_started[session_id]) do
            self._chunk_stream_started[session_id][chunk_type] = false
        end
    end

    ACPClient.__handle_session_update(self, params)
end

--- Extract diff from content array (standard ACP diff content type)
--- @param update agentic.acp.ToolCallMessage|agentic.acp.CursorToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallDiff|nil diff
--- @return string|nil path
function CursorACPAdapter:_extract_content_diff(update)
    local content = update.content and update.content[1]
    if not content or content.type ~= "diff" then
        return nil, nil
    end

    --- @type agentic.ui.MessageWriter.ToolCallDiff
    local diff = {
        new = self:safe_split(content.newText),
        old = self:safe_split(content.oldText),
    }

    return diff, content.path
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.CursorToolCallMessage
function CursorACPAdapter:__handle_tool_call(session_id, update)
    local kind = update.kind
    local argument = update.title
    if kind == "read" then
        argument = self:_format_read_argument(nil, update.title)
    elseif kind == "edit" then
        argument = format_file_argument("edit", nil, update.title)
    elseif kind == "search" then
        argument = self:_format_search_argument(nil, update.title)
    end

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = argument,
    }

    if update.rawInput and not vim.tbl_isempty(update.rawInput) then
        -- rawInput available: extract provider-specific fields
        if kind == "read" then
            message.argument =
                self:_format_read_argument(update.rawInput, update.title)
        elseif kind == "edit" then
            message.argument =
                format_file_argument("edit", update.rawInput, update.title)
            message.diff = self:_build_edit_diff(update.rawInput)
        elseif kind == "search" then
            message.argument =
                self:_format_search_argument(update.rawInput, update.title)
        elseif kind == "fetch" then
            if update.rawInput.query then
                message.kind = "WebSearch"
                message.argument = update.rawInput.query
            elseif update.rawInput.url then
                message.argument = update.rawInput.url

                if update.rawInput.prompt then
                    message.argument = string.format(
                        "%s %s",
                        message.argument,
                        update.rawInput.prompt
                    )
                end
            else
                message.argument = "unknown fetch"
            end
        ---@diagnostic disable-next-line: invisible
        elseif update.rawInput._toolName == "task" then
            local raw_input = update.rawInput
            ---@cast raw_input agentic.acp.CursorTaskRawInput
            self._task_tool_inputs[update.toolCallId] = raw_input
            message.kind = "SubAgent"
            message.argument =
                self:_format_task_argument(raw_input, update.title)
        else
            local command = update.rawInput.command
            if type(command) == "table" then
                command = table.concat(command, " ")
            end

            message.argument = command or update.title or ""
            message.body = self:extract_content_body(update)
        end
    elseif update.content and #update.content > 0 then
        -- No rawInput: try content-based diff (standard ACP format)
        if kind == "edit" then
            local diff, path = self:_extract_content_diff(update)
            if diff then
                message.diff = diff
                if path then
                    message.argument = FileSystem.to_smart_path(path)
                end
            end
        else
            message.body = self:extract_content_body(update)
        end
    end

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call(message)
    end)
end

--- Build enriched update from rawOutput/content fields that cursor
--- sends on tool_call_update (not on the initial tool_call).
--- @protected
--- @param update agentic.acp.CursorToolCallUpdate
--- @return agentic.ui.MessageWriter.ToolCallBase message
function CursorACPAdapter:__build_tool_call_update(update)
    --- @type agentic.ui.MessageWriter.ToolCallBase
    local message = {
        tool_call_id = update.toolCallId,
        status = update.status,
    }

    -- Edit diffs arrive in standard ACP content format (content[1].type == "diff")
    if update.content and #update.content > 0 then
        local diff, path = self:_extract_content_diff(update)
        if diff then
            message.diff = diff
            if path then
                message.argument = FileSystem.to_smart_path(path)
            end
            return message
        end
    end

    -- Read, execute, and search results arrive in rawOutput
    local rawOutput = update.rawOutput
    if rawOutput then
        local task_input = rawget(self._task_tool_inputs, update.toolCallId)
        if task_input then
            local final_message = extract_task_final_message(rawOutput)
            if final_message then
                message.kind = "SubAgent"
                message.argument =
                    self:_format_task_argument(task_input, update.title)
                message.body = self:_build_task_body(task_input, {
                    final_message = final_message,
                })
            end
        elseif rawOutput.content then
            -- read kind: rawOutput.content is the file text
            message.body = self:safe_split(rawOutput.content)
        elseif rawOutput.stdout then
            -- execute kind: rawOutput.stdout/stderr
            message.body = self:safe_split(rawOutput.stdout)
        elseif rawOutput.totalFiles ~= nil then
            -- search kind: cursor only sends metadata, not actual results
            local suffix = rawOutput.truncated and " (truncated)" or ""
            message.body = {
                string.format(
                    "Found %d file(s)%s",
                    rawOutput.totalFiles,
                    suffix
                ),
            }
        end
    end

    if update.kind == "search" then
        message.argument =
            self:_format_search_argument(update.rawInput, update.title)
    elseif update.kind == "read" then
        message.argument =
            self:_format_read_argument(update.rawInput, update.title)
    end

    -- Fall back to standard content extraction
    if not message.body and not message.diff then
        message.body = self:extract_content_body(update)
    end

    return message
end

--- Cursor sends tool_call_update without status for in_progress,
--- and with rawOutput/content on completion.
--- @protected
--- @param session_id string
--- @param update agentic.acp.CursorToolCallUpdate
function CursorACPAdapter:__handle_tool_call_update(session_id, update)
    if not update.status then
        return
    end

    local message = self:__build_tool_call_update(update)

    self:__with_subscriber(session_id, function(subscriber)
        subscriber.on_tool_call_update(message)
    end)
end

--- Cursor extension: cursor/task notifies about subagent task completion.
--- Params shape:
---   { agentId, description, durationMs, model, prompt, subagentType, toolCallId }
--- @class agentic.acp.CursorTaskParams
--- @field agentId string
--- @field description string
--- @field durationMs? number
--- @field finalMessage? string
--- @field model string
--- @field prompt string
--- @field subagentType table
--- @field toolCallId string

--- Handle cursor/task request — subagent task completion notification.
--- Sends an acknowledgment response and routes the task info as a tool call update body.
--- @param message_id number|nil
--- @param params agentic.acp.CursorTaskParams
function CursorACPAdapter:_handle_cursor_task(message_id, params)
    -- Acknowledge the request so cursor doesn't block
    if message_id then
        self:__send_result(message_id, vim.empty_dict())
    end

    if not params or not params.toolCallId then
        Logger.debug(
            "CursorACPAdapter",
            "cursor/task without toolCallId, ignoring"
        )
        return
    end

    local final_message = extract_task_final_message(params)
    local body = self:_build_task_body(params, {
        final_message = final_message,
    })

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local update = {
        tool_call_id = params.toolCallId,
        kind = "SubAgent",
        status = "completed",
        argument = self:_format_task_argument(params, nil),
        body = body,
    }

    -- cursor/task doesn't include sessionId, so find the subscriber that owns this tool call
    for session_id, _ in pairs(self.subscribers) do
        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call_update(update)
        end)
    end
end

--- @param params table|nil
--- @return string|nil session_id
function CursorACPAdapter:_resolve_cursor_session_id(params)
    if params and params.sessionId and params.sessionId ~= "" then
        return params.sessionId
    end

    --- @type string[]
    local ids = {}
    for sid, _ in pairs(self.subscribers) do
        table.insert(ids, sid)
    end

    if #ids == 1 then
        return ids[1]
    end

    return nil
end

--- Dispatch a Cursor extension JSON-RPC request to the session subscriber (one response per id).
--- @param message_id number|nil
--- @param method string
--- @param params table|nil
function CursorACPAdapter:_emit_cursor_extension(message_id, method, params)
    local session_id = self:_resolve_cursor_session_id(params)
    if not session_id then
        Logger.debug(
            "CursorACPAdapter",
            "cursor extension "
                .. method
                .. ": no sessionId and not exactly one subscriber; ack only"
        )
        if message_id then
            self:__send_result(message_id, vim.empty_dict())
        end
        return
    end

    local responded = false
    --- @param result table|nil
    local function respond(result)
        if not message_id or responded then
            return
        end
        responded = true
        self:__send_result(message_id, result or vim.empty_dict())
    end

    self:__with_subscriber(session_id, function(subscriber)
        if subscriber.on_cursor_extension then
            --- @type agentic.acp.CursorExtensionContext
            local ctx = {
                message_id = message_id,
                method = method,
                params = params or {},
                respond = respond,
            }
            subscriber.on_cursor_extension(ctx)
        elseif message_id then
            self:__send_result(message_id, vim.empty_dict())
        end
    end)
end

--- Cursor sends `tool_call` for execute kind with `title = "Terminal"` and no
--- `rawInput.command`, but the permission request for the same tool call
--- contains the actual command in `toolCall.title` wrapped in backticks.
--- Build a partial tool call update from the permission payload only for
--- execute kind, so the chat block above the permission buttons shows the
--- actual terminal command.
--- @param tool_call agentic.acp.ToolCall
--- @return agentic.ui.MessageWriter.ToolCallBase|nil update
function CursorACPAdapter:__build_permission_tool_call_update(tool_call)
    local _ = self
    if
        not tool_call
        or not tool_call.toolCallId
        or tool_call.kind ~= "execute"
    then
        return nil
    end

    local raw_input = tool_call.rawInput --[[@as agentic.acp.CursorRawInput|nil]]
    local argument
    if raw_input and not vim.tbl_isempty(raw_input) then
        local command = raw_input.command
        if type(command) == "table" then
            command = table.concat(command, " ")
        end
        if type(command) == "string" and command ~= "" then
            argument = command
        end
    end

    if not argument and tool_call.title then
        argument = tool_call.title:match("^`(.+)`$") or tool_call.title
    end

    if not argument or argument == "" then
        return nil
    end

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local update = {
        tool_call_id = tool_call.toolCallId,
        kind = "execute",
        argument = argument,
    }
    return update
end

--- Extract it and update the tool call block argument before the permission
--- buttons are rendered.
--- @protected
--- @param message_id number
--- @param request agentic.acp.RequestPermission
function CursorACPAdapter:__handle_request_permission(message_id, request)
    local update = self:__build_permission_tool_call_update(request.toolCall)
    if update then
        local session_id = request.sessionId

        self:__with_subscriber(session_id, function(subscriber)
            subscriber.on_tool_call_update(update)
        end)
    end

    ACPClient.__handle_request_permission(self, message_id, request)
end

--- Override notification handler to intercept Cursor extension methods.
--- @param message_id number|nil
--- @param method string
--- @param params table|nil
function CursorACPAdapter:_handle_notification(message_id, method, params)
    if method == "cursor/task" then
        self:_handle_cursor_task(
            message_id,
            (params or {}) --[[@as agentic.acp.CursorTaskParams]]
        )
    elseif
        method == "cursor/update_todos"
        or method == "cursor/generate_image"
        or method == "cursor/ask_question"
        or method == "cursor/create_plan"
    then
        self:_emit_cursor_extension(message_id, method, params)
    else
        ACPClient._handle_notification(self, message_id, method, params or {})
    end
end

return CursorACPAdapter
