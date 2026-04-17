--- Mock implementation of agentic.acp.ACPTransportModule for testing
--- @class agentic.acp.ACPTransportModuleMock
local M = {}

--- @class agentic.acp.ACPTransportModuleMockInstance
--- @field stdin any
--- @field stdout any
--- @field process any
--- @field _config agentic.acp.StdioTransportConfig
--- @field _callbacks agentic.acp.TransportCallbacks
--- @field _started boolean
--- @field _stopped boolean
--- @field callbacks agentic.acp.TransportCallbacks
--- @field send? fun(self: agentic.acp.ACPTransportModuleMockInstance, data: string): boolean
--- @field start? fun(self: agentic.acp.ACPTransportModuleMockInstance)
--- @field stop? fun(self: agentic.acp.ACPTransportModuleMockInstance)

--- Create a mock stdio transport for testing
--- @param config agentic.acp.StdioTransportConfig
--- @param callbacks agentic.acp.TransportCallbacks
--- @return agentic.acp.ACPTransportModuleMockInstance
function M.create_stdio_transport(config, callbacks)
    --- @type agentic.acp.ACPTransportModuleMockInstance
    local transport = {
        stdin = nil,
        stdout = nil,
        process = nil,
        _config = config,
        _callbacks = callbacks,
        _started = false,
        _stopped = false,
        callbacks = callbacks,
    }

    --- @param _data string
    function transport:send(_data)
        if self._stopped then
            return false
        end
        return true
    end

    function transport:start()
        self._started = true
        self._callbacks.on_state_change("connecting")
    end

    function transport:stop()
        self._stopped = true
        self._callbacks.on_state_change("disconnected")
    end

    return transport
end

return M
