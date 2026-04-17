local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic.acp.AgentModes", function()
    --- @type agentic.acp.AgentModes
    local AgentModes

    --- @type agentic.acp.AgentModes
    local agent_modes

    --- @type agentic.acp.ModesInfo
    local modes_info = {
        availableModes = {
            { id = "normal", name = "Normal", description = "Standard mode" },
            { id = "plan", name = "Plan", description = "Planning mode" },
            { id = "code", name = "Code", description = "Coding mode" },
        },
        currentModeId = "normal",
    }

    before_each(function()
        AgentModes = require("agentic.acp.agent_modes")
        agent_modes = AgentModes:new()
        agent_modes:set_modes(modes_info)
    end)

    describe("get_mode", function()
        it("returns mode with matching id", function()
            local result = agent_modes:get_mode("plan")

            assert.is_not_nil(result)
            if result ~= nil then
                assert.equal("plan", result.id)
                assert.equal("Plan", result.name)
            end
        end)

        it("returns nil for non-existent or empty modes", function()
            assert.is_nil(agent_modes:get_mode("nonexistent"))

            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })
            assert.is_nil(agent_modes:get_mode("any_id"))
        end)
    end)

    describe("handle_agent_update_mode", function()
        --- @type TestStub
        local notify_stub

        before_each(function()
            local Logger = require("agentic.utils.logger")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
        end)

        it("updates current_mode_id and notifies on valid mode", function()
            local success = agent_modes:handle_agent_update_mode("code")

            assert.is_true(success)
            assert.equal("code", agent_modes.current_mode_id)
            assert.stub(notify_stub).was.called(1)
            local first_call = assert.not_nil(notify_stub.calls[1])
            assert.is_true(string.find(first_call[1], "code") ~= nil)
        end)

        it("returns false and warns for nil or invalid mode_id", function()
            assert.is_false(agent_modes:handle_agent_update_mode(nil))
            assert.is_false(agent_modes:handle_agent_update_mode("nonexistent"))

            assert.equal("normal", agent_modes.current_mode_id)
            assert.stub(notify_stub).was.called(2)
            local first_call = assert.not_nil(notify_stub.calls[1])
            local second_call = assert.not_nil(notify_stub.calls[2])
            assert.equal(vim.log.levels.WARN, first_call[2])
            assert.equal(vim.log.levels.WARN, second_call[2])
        end)

        it("returns false when modes list is empty", function()
            agent_modes:set_modes({ availableModes = {}, currentModeId = "" })

            assert.is_false(agent_modes:handle_agent_update_mode("plan"))
            assert.stub(notify_stub).was.called(0)
        end)
    end)

    describe("clear", function()
        it("resets modes and current_mode_id", function()
            agent_modes:clear()

            assert.is_nil(agent_modes:get_mode("normal"))
            assert.is_nil(agent_modes:get_mode("plan"))
            assert.is_nil(agent_modes.current_mode_id)
        end)
    end)
end)
