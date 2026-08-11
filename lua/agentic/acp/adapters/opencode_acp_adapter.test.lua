--- @diagnostic disable: access-invisible, missing-fields
local assert = require("tests.helpers.assert")
local OpenCodeACPAdapter = require("agentic.acp.adapters.opencode_acp_adapter")

local function new_adapter()
    return setmetatable({
        provider_config = {},
        subscribers = {},
        callbacks = {},
        _raw_output_deltas = {},
    }, OpenCodeACPAdapter)
end

describe("agentic.acp.adapters.OpenCodeACPAdapter", function()
    it("treats cancelled tool calls as terminal updates", function()
        local adapter = new_adapter()
        local messages = {}
        adapter.subscribers.session = {
            on_tool_call_update = function(message)
                table.insert(messages, message)
            end,
        }

        adapter:__handle_tool_call_update("session", {
            sessionUpdate = "tool_call_update",
            toolCallId = "tool-1",
            status = "cancelled",
            title = "edit",
            rawInput = {
                filePath = "file.lua",
                newString = "new",
                oldString = "old",
            },
        })

        assert.is_true(vim.wait(1000, function()
            return #messages == 1
        end, 10))
        assert.equal("cancelled", messages[1].status)
        assert.is_nil(messages[1].diff)
        assert.is_nil(messages[1].body)
    end)
end)
