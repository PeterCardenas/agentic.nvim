local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.acp.MistralVibeACPAdapter : agentic.acp.ACPClient
--- @field _raw_output_deltas table<string, table<string, string[]>>
--- @field _tool_call_states table<string, table<string, { terminal: boolean }>>
--- @field _tool_call_generations table<string, table<string, number>>
local MistralVibeACPAdapter = setmetatable({}, { __index = ACPClient })
MistralVibeACPAdapter.__index = MistralVibeACPAdapter

--- @param config agentic.acp.ACPProviderConfig
--- @param on_ready fun(client: agentic.acp.ACPClient)
--- @return agentic.acp.MistralVibeACPAdapter
function MistralVibeACPAdapter:new(config, on_ready)
    -- Call parent constructor with parent class
    self = ACPClient.new(ACPClient, config, on_ready)

    -- Re-metatable to child class for proper inheritance chain
    self = setmetatable(self, MistralVibeACPAdapter) --[[@as agentic.acp.MistralVibeACPAdapter]]
    self._raw_output_deltas = {}
    self._tool_call_states = {}
    self._tool_call_generations = {}

    return self
end

--- @param session_id string
function MistralVibeACPAdapter:_clear_session_raw_output(session_id)
    self._raw_output_deltas[session_id] = nil
end

--- @param session_id string
function MistralVibeACPAdapter:_clear_session_tool_call_state(session_id)
    self._tool_call_states = self._tool_call_states or {}
    self._tool_call_generations = self._tool_call_generations or {}
    self._tool_call_states[session_id] = nil
    self._tool_call_generations[session_id] = nil
end

--- @param session_id string
function MistralVibeACPAdapter:_clear_session_lifecycle(session_id)
    self:_clear_session_raw_output(session_id)
    self:_clear_session_tool_call_state(session_id)
end

--- @param session_id string
--- @param tool_call_id string
function MistralVibeACPAdapter:_begin_tool_call(session_id, tool_call_id)
    self._tool_call_states = self._tool_call_states or {}
    self._tool_call_generations = self._tool_call_generations or {}
    self._tool_call_states[session_id] = self._tool_call_states[session_id]
        or {}
    self._tool_call_generations[session_id] = self._tool_call_generations[session_id]
        or {}
    self._tool_call_generations[session_id][tool_call_id] = (
        self._tool_call_generations[session_id][tool_call_id] or 0
    ) + 1
    self._tool_call_states[session_id][tool_call_id] = { terminal = false }

    local session_deltas = self._raw_output_deltas[session_id] or {}
    session_deltas[tool_call_id] = nil
    if vim.tbl_isempty(session_deltas) then
        self._raw_output_deltas[session_id] = nil
    end
end

--- @param tool_call_id unknown
--- @return boolean
local function is_valid_tool_call_id(tool_call_id)
    return type(tool_call_id) == "string" and tool_call_id ~= ""
end

--- @param status string|nil
--- @return boolean
local function is_terminal_status(status)
    return status == "completed" or status == "failed" or status == "cancelled"
end

--- @param session_id string
function MistralVibeACPAdapter:cancel_session(session_id)
    if not session_id then
        return
    end

    self:_clear_session_lifecycle(session_id)
    ACPClient.cancel_session(self, session_id)
end

--- @param json_str string|nil
--- @return table decoded_json
function MistralVibeACPAdapter:_decode_json(json_str)
    local _ = self
    local decode_ok, json = pcall(vim.json.decode, json_str or "{}")

    if not decode_ok then
        Logger.notify("Mistral JSON decoding failed: " .. vim.inspect(json))
        return {}
    end

    if type(json) ~= "table" then
        return {}
    end

    return json
end

--- @class agentic.acp.MistralVibeToolCallMessage : agentic.acp.ToolCallMessage
--- @field rawInput? string

--- @alias agentic.acp.MistralVibeRawInputJson
--- | { file_path: string }
--- | { task: string, agent: string }

--- @param update agentic.acp.MistralVibeToolCallMessage
--- @return agentic.ui.MessageWriter.ToolCallBlock message
function MistralVibeACPAdapter:__build_tool_call_message(update)
    --- @type agentic.ui.MessageWriter.ToolCallBlock
    local message = {
        tool_call_id = update.toolCallId,
        kind = update.kind == "other" and "execute" or update.kind,
        status = update.status or "pending",
        argument = update.title,
        body = self:extract_content_body(update),
    }

    if update.kind == "edit" then
        local content = update.content and update.content[1]
        if content then
            if content.type == "diff" then
                message.diff = {
                    new = self:safe_split(content.newText),
                    old = self:safe_split(content.oldText),
                    all = false,
                }
                if content.path then
                    message.argument = FileSystem.to_smart_path(content.path)
                end
            end
        end
    else
        local json = self:_decode_json(update.rawInput) --[[@as agentic.acp.MistralVibeRawInputJson]]

        if json.agent then
            message.kind = "SubAgent"
            message.argument =
                string.format("Agent %s: %s", json.agent or "", json.task or "")
            message.body = {
                update.title or "",
            }
        end
    end

    return message
end

--- @class agentic.acp.MistralVibeToolCallUpdate : agentic.acp.ToolCallUpdate
--- @field rawOutput? string a JSON string
--- @field kind? agentic.acp.ToolKind

--- @alias agentic.acp.MistralVibeRawOutputJson
--- | { stdout: string, stderr: string }
--- | { response: string, turns_used: number, completed: boolean }
--- | { matches: string, match_count: number, was_truncated: boolean }

--- @protected
--- @param update agentic.acp.MistralVibeToolCallUpdate
--- @param session_id string|nil
--- @return agentic.ui.MessageWriter.ToolCallBase message
function MistralVibeACPAdapter:__build_tool_call_update(update, session_id)
    local message = ACPClient.__build_tool_call_update(self, update)
    if not is_valid_tool_call_id(update.toolCallId) then
        return message
    end

    local json = self:_decode_json(update.rawOutput)

    --- @type string[]|nil
    local new_body

    -- Empty stream fields are not output deltas. In particular, safe_split("")
    -- returns two empty-looking lines, which would incorrectly replace normal
    -- ACP content and add a separator on the next real delta.
    if type(json.stdout) == "string" and json.stdout ~= "" then
        new_body = self:safe_split(json.stdout)
    end
    if type(json.stderr) == "string" and json.stderr ~= "" then
        new_body = new_body or {}
        vim.list_extend(new_body, self:safe_split(json.stderr))
    elseif not new_body and json.turns_used then
        if type(json.response) == "string" and json.response ~= "" then
            new_body = self:safe_split(json.response)
        end
    elseif
        not new_body
        and type(json.matches) == "string"
        and json.matches ~= ""
    then
        new_body = self:safe_split(json.matches)
    end

    session_id = session_id or "__direct__"
    local session_deltas = self._raw_output_deltas
        and self._raw_output_deltas[session_id]
    local body = session_deltas and session_deltas[update.toolCallId]
    if new_body and #new_body > 0 then
        self._raw_output_deltas = self._raw_output_deltas or {}
        session_deltas = session_deltas or {}
        self._raw_output_deltas[session_id] = session_deltas
        if body == nil then
            body = {}
            session_deltas[update.toolCallId] = body
        else
            vim.list_extend(body, { "", "---", "" })
        end
        vim.list_extend(body, new_body)
        message.body = vim.list_extend({}, body)
    elseif body ~= nil then
        message.body = vim.list_extend({}, body)
    end

    if is_terminal_status(update.status) and session_deltas then
        session_deltas[update.toolCallId] = nil
        if vim.tbl_isempty(session_deltas) then
            self._raw_output_deltas[session_id] = nil
        end
    end

    return message
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.MistralVibeToolCallMessage
function MistralVibeACPAdapter:__handle_tool_call(session_id, update)
    if
        type(update) ~= "table" or not is_valid_tool_call_id(update.toolCallId)
    then
        return
    end

    self:_begin_tool_call(session_id, update.toolCallId)
    ACPClient.__handle_tool_call(
        self,
        session_id,
        update --[[@as agentic.acp.ToolCallMessage]]
    )
end

--- @protected
--- @param session_id string
--- @param update agentic.acp.MistralVibeToolCallUpdate
function MistralVibeACPAdapter:__handle_tool_call_update(session_id, update)
    if
        type(update) ~= "table"
        or not update.status
        or not is_valid_tool_call_id(update.toolCallId)
        or not self.subscribers[session_id]
    then
        return
    end

    local session_states = self._tool_call_states
        and self._tool_call_states[session_id]
    local state = session_states and session_states[update.toolCallId]
    if state and state.terminal then
        return
    end
    if not state then
        self:_begin_tool_call(session_id, update.toolCallId)
    end

    local tool_call_generation = self._tool_call_generations
        and self._tool_call_generations[session_id]
        and self._tool_call_generations[session_id][update.toolCallId]
    local message = self:__build_tool_call_update(update, session_id)
    if is_terminal_status(update.status) then
        session_states = self._tool_call_states[session_id]
        session_states[update.toolCallId].terminal = true
    end

    self:__with_subscriber(session_id, function(subscriber)
        -- Subscriber delivery is scheduled. A new tool_call with the same ID
        -- may replace this lifecycle before the callback runs.
        local current_generation = self._tool_call_generations
            and self._tool_call_generations[session_id]
            and self._tool_call_generations[session_id][update.toolCallId]
        if current_generation ~= tool_call_generation then
            return
        end
        subscriber.on_tool_call_update(message)
    end)
end

--- @param session_id string
function MistralVibeACPAdapter:stop_generation(session_id)
    if not session_id then
        return
    end

    self:_clear_session_lifecycle(session_id)
    ACPClient.stop_generation(self, session_id)
end

return MistralVibeACPAdapter
