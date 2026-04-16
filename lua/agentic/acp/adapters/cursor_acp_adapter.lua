--- @diagnostic disable: unnecessary-if
local ACPClient = require("agentic.acp.acp_client")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")

--- @class agentic.acp.CursorRawInput : agentic.acp.RawInput
--- @field content? string For creating new files instead of new_string

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

--- Cursor-specific adapter that extends ACPClient with Cursor-specific behaviors
--- @class agentic.acp.CursorACPAdapter : agentic.acp.ACPClient
--- @field _available_commands_updates table<string, table> Cursor sends available commands before session starts, indexed by session ID, to be processed after session creation
--- @field _chunk_stream_started table<string, table<string, boolean>> Track whether a chunk stream started per session and chunk type
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

    return self
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
                self._available_commands_updates[result.sessionId]
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
        if
            content
            and content.type == "text"
            and type(content.text) == "string"
        then
            if not stream_started then
                content.text = content.text:gsub("^\n+", "")
                if content.text == "" then
                    by_session[update_type] = true
                    self._chunk_stream_started[session_id] = by_session
                    return
                end
            end
        end
        by_session[update_type] = true
        self._chunk_stream_started[session_id] = by_session
    elseif session_id and self._chunk_stream_started[session_id] then
        -- A non-chunk update means the previous stream ended; reset.
        self._chunk_stream_started[session_id] = nil
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

    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = kind,
        status = update.status,
        argument = update.title,
    }

    if update.rawInput and not vim.tbl_isempty(update.rawInput) then
        -- rawInput available: extract provider-specific fields
        if kind == "read" or kind == "edit" then
            local file_path = update.rawInput.file_path
            if file_path and file_path ~= "" then
                message.argument = FileSystem.to_smart_path(file_path)
            end

            if kind == "edit" then
                local new_string = update.rawInput.content
                    or update.rawInput.new_string
                local old_string = update.rawInput.old_string

                message.diff = {
                    new = self:safe_split(new_string),
                    old = self:safe_split(old_string),
                    all = update.rawInput.replace_all or false,
                }
            end
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
        if rawOutput.content then
            -- read kind: rawOutput.content is the file text
            message.body = self:safe_split(rawOutput.content)
        elseif rawOutput.stdout then
            -- execute kind: rawOutput.stdout/stderr
            message.body = self:safe_split(rawOutput.stdout)
        elseif rawOutput.totalFiles then
            -- search kind: cursor only sends metadata, not actual results
            message.body = {
                string.format("Found %d file(s)", rawOutput.totalFiles),
            }
        end
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
--- @field durationMs number
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

    local duration_str = ""
    if params.durationMs then
        duration_str = string.format(" (%.1fs)", params.durationMs / 1000)
    end

    local description = params.description or "subagent task"

    --- @type agentic.ui.MessageWriter.ToolCallBase
    local update = {
        tool_call_id = params.toolCallId,
        status = "completed",
        argument = description,
        body = {
            string.format("⚡ %s%s", description, duration_str),
        },
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
