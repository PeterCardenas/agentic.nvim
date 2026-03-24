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
    local update_type = params.update.sessionUpdate

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

return CursorACPAdapter
