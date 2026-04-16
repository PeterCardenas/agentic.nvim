---@diagnostic disable: unnecessary-if
--- Full mock transport that completes the ACP handshake and allows message injection.
--- Unlike acp_transport_mock.lua which only sets "connecting" state,
--- this mock transitions to "connected", auto-responds to initialize/session/new,
--- and provides inject_notification() + complete_prompt() for test control.
---
--- Usage (inside child or test process):
---   package.loaded["agentic.acp.acp_transport"] = require("tests.mocks.acp_transport_full_mock")
---   -- After agentic.setup() and toggle(), the session will be fully initialized.
---   -- Use the global `_agentic_mock_transport` to inject messages.
---
--- @class agentic.acp.ACPTransportFullMock
local M = {}

--- The most recently created transport instance, exposed for test code.
--- @type agentic.acp.ACPTransportFullMockInstance|nil
M.instance = nil

local SESSION_ID = "mock-session-001"
local NEXT_PROMPT_ID_KEY = "_next_prompt_request_id"

--- @class agentic.acp.ACPTransportFullMockInstance
--- @field _callbacks agentic.acp.TransportCallbacks
--- @field _started boolean
--- @field _stopped boolean
--- @field _sent table[] Captured outgoing requests for assertions
--- @field _next_prompt_request_id number|nil The JSON-RPC id of the pending session/prompt request
--- @field inject_notification? fun(self: agentic.acp.ACPTransportFullMockInstance, session_id: string, update: table)
--- @field complete_prompt? fun(self: agentic.acp.ACPTransportFullMockInstance, stop_reason: string|nil)

--- @param config agentic.acp.StdioTransportConfig
--- @param callbacks agentic.acp.TransportCallbacks
--- @return agentic.acp.ACPTransportFullMockInstance
function M.create_stdio_transport(config, callbacks)
    local transport = {
        stdin = nil,
        stdout = nil,
        process = nil,
        _config = config,
        _callbacks = callbacks,
        _started = false,
        _stopped = false,
        _sent = {},
        [NEXT_PROMPT_ID_KEY] = nil,
    }

    --- @param data string
    --- @diagnostic disable: invisible
    function transport:send(data)
        if self._stopped then
            return false
        end

        local ok, message = pcall(vim.json.decode, data)
        if not ok then
            return true
        end

        table.insert(self._sent, message)

        -- Auto-respond to known handshake methods
        if message.method == "initialize" then
            vim.schedule(function()
                --- @diagnostic disable-next-line: missing-fields
                self._callbacks.on_message({
                    jsonrpc = "2.0",
                    id = message.id,
                    result = {
                        protocolVersion = 1,
                        agentCapabilities = {
                            loadSession = false,
                            promptCapabilities = {
                                image = false,
                                audio = false,
                                embeddedContext = true,
                            },
                        },
                    },
                })
            end)
        elseif message.method == "session/new" then
            vim.schedule(function()
                --- @diagnostic disable-next-line: missing-fields
                self._callbacks.on_message({
                    jsonrpc = "2.0",
                    id = message.id,
                    result = {
                        sessionId = SESSION_ID,
                    },
                })
            end)
        elseif message.method == "session/prompt" then
            -- Store the request id so tests can complete it later
            self[NEXT_PROMPT_ID_KEY] = message.id
        elseif message.method == "session/cancel" then
            -- no-op, just acknowledge
        elseif
            message.method == "session/set_config_option"
            or message.method == "session/set_mode"
            or message.method == "session/set_model"
        then
            vim.schedule(function()
                --- @diagnostic disable-next-line: missing-fields
                self._callbacks.on_message({
                    jsonrpc = "2.0",
                    id = message.id,
                    result = vim.empty_dict(),
                })
            end)
        end

        return true
    end

    function transport:start()
        self._started = true
        -- Transition through connecting → connected (real transport does this synchronously)
        self._callbacks.on_state_change("connecting")
        self._callbacks.on_state_change("connected")
    end

    function transport:stop()
        self._stopped = true
        self._callbacks.on_state_change("disconnected")
    end

    --- Inject a session/update notification (simulates agent sending a message chunk, tool call, etc.)
    --- @param session_id string
    --- @param update table The session update payload (e.g. { sessionUpdate = "agent_message_chunk", content = { type = "text", text = "Hello" } })
    function transport:inject_notification(session_id, update)
        --- @diagnostic disable-next-line: missing-fields, assign-type-mismatch
        self._callbacks.on_message({
            jsonrpc = "2.0",
            method = "session/update",
            params = {
                sessionId = session_id,
                --- @diagnostic disable-next-line: assign-type-mismatch
                update = update,
            },
        })
    end

    --- Complete the pending session/prompt request (simulates agent finishing the turn).
    --- @param stop_reason string|nil Stop reason (default "end_turn")
    function transport:complete_prompt(stop_reason)
        local id = self[NEXT_PROMPT_ID_KEY]
        if not id then
            error("No pending prompt request to complete")
        end
        self[NEXT_PROMPT_ID_KEY] = nil

        --- @diagnostic disable-next-line: missing-fields
        self._callbacks.on_message({
            jsonrpc = "2.0",
            --- @diagnostic disable-next-line: assign-type-mismatch
            id = id,
            result = {
                stopReason = stop_reason or "end_turn",
            },
        })
    end

    --- @type agentic.acp.ACPTransportFullMockInstance
    local instance = transport
    M.instance = instance

    return transport
end

--- The fixed session ID used by this mock.
M.SESSION_ID = SESSION_ID

return M
