local assert = require("tests.helpers.assert")

describe("agentic.acp.AgentInstance", function()
    before_each(function()
        package.loaded["agentic.config"] = nil
        package.loaded["agentic.config_default"] = nil
        package.loaded["agentic.acp.agent_instance"] = nil
        package.loaded["agentic.acp.acp_client"] = nil
        package.loaded["agentic.acp.acp_transport"] = nil
        package.preload["agentic.acp.acp_transport"] = nil
    end)

    after_each(function()
        local AgentInstance = package.loaded["agentic.acp.agent_instance"]
        if AgentInstance and AgentInstance._instances then
            AgentInstance._instances = {}
        end
    end)

    it("registers pi-acp as a default provider", function()
        local DefaultConfig = require("agentic.config_default")
        local pi_provider =
            assert.not_nil(DefaultConfig.acp_providers["pi-acp"])

        assert.equal("Pi ACP", pi_provider.name)
        assert.equal("pi-acp", pi_provider.command)
        assert.same({}, pi_provider.args)
        assert.same({}, pi_provider.env)
    end)

    it("creates a generic ACP client for pi-acp", function()
        package.preload["agentic.acp.acp_transport"] = function()
            return {
                create_stdio_transport = function(_config, callbacks)
                    return {
                        start = function()
                            callbacks.on_state_change("connected")
                        end,
                        send = function(_, data)
                            local message = vim.json.decode(data)
                            if message.method == "initialize" then
                                callbacks.on_message({
                                    jsonrpc = "2.0",
                                    id = message.id,
                                    result = {
                                        protocolVersion = 1,
                                        agentCapabilities = {},
                                    },
                                })
                            end
                            return true
                        end,
                        stop = function() end,
                    }
                end,
            }
        end

        local AgentInstance = require("agentic.acp.agent_instance")
        local ready_client

        local client = AgentInstance.get_instance("pi-acp", function(new_client)
            ready_client = new_client
        end)

        assert.not_nil(client)
        assert.equal(client, ready_client)
        assert.equal("pi-acp", client.provider_config.command)
    end)
end)
