--- @diagnostic disable: access-invisible, missing-fields, param-type-mismatch, redundant-parameter
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local GeminiACPAdapter = require("agentic.acp.adapters.gemini_acp_adapter")

--- @return agentic.acp.GeminiACPAdapter
local function new_adapter()
    return setmetatable({
        provider_config = { name = "Gemini", command = "gemini" },
        subscribers = {},
        _subscriber_generations = {},
        callbacks = {},
        transport = { send = function() end },
    }, GeminiACPAdapter)
end

describe("agentic.acp.adapters.GeminiACPAdapter", function()
    it("cancels permission when the subscriber is already gone", function()
        local sent = {}
        local adapter = new_adapter()
        adapter.transport.send = function(_, data)
            table.insert(sent, vim.json.decode(data))
        end

        adapter:__handle_request_permission(21, {
            sessionId = "missing-session",
            toolCall = { toolCallId = "tool-1", kind = "execute", title = "ls" },
        })

        assert.equal(1, #sent)
        assert.equal(21, sent[1].id)
        assert.same({ outcome = { outcome = "cancelled" } }, sent[1].result)
    end)

    it("responds once when cancellation races a selected permission", function()
        local sent = {}
        local adapter = new_adapter()
        adapter.transport.send = function(_, data)
            table.insert(sent, vim.json.decode(data))
        end
        local scheduled = {}
        local schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(callback)
            table.insert(scheduled, callback)
        end)

        local callback
        adapter:_subscribe("session-1", {
            on_request_permission = function(_, respond)
                callback = respond
            end,
            on_tool_call = function() end,
        })
        adapter:__handle_request_permission(22, {
            sessionId = "session-1",
            toolCall = { toolCallId = "tool-1", kind = "execute", title = "ls" },
        })
        adapter:cancel_session("session-1")
        for _, fn in ipairs(scheduled) do
            fn()
        end
        schedule_stub:revert()

        local responses = vim.tbl_filter(function(message)
            return message.result ~= nil
        end, sent)
        assert.equal(1, #responses)
        assert.same(
            { outcome = { outcome = "cancelled" } },
            responses[1].result
        )
        assert.is_nil(callback)
    end)
end)
