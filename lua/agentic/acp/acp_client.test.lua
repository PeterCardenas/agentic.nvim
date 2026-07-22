--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")

--- @return agentic.acp.ACPClient client
local function new_client()
    --- @type agentic.acp.ACPClient
    local client = setmetatable({
        provider_config = {
            name = "Test ACP",
            command = "test-acp",
            timeout = 1,
        },
        id_counter = 0,
        callbacks = {},
        subscribers = {},
        transport = {
            send = function()
                return true
            end,
        },
    }, ACPClient)
    return client
end

describe("agentic.acp.ACPClient", function()
    describe("_send_request timeout", function()
        --- @type TestStub
        local defer_stub
        --- @type TestStub
        local notify_stub

        before_each(function()
            defer_stub = spy.stub(vim, "defer_fn")
            defer_stub:invokes(function(callback, _timeout)
                callback()
            end)
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            defer_stub:revert()
            notify_stub:revert()
        end)

        it(
            "removes callback and ignores late responses after timeout",
            function()
                local client = new_client()
                local callback_spy = spy.new(function() end)

                client:_send_request(
                    "session/prompt",
                    { sessionId = "session-1" },
                    callback_spy --[[@as function]]
                )

                assert.spy(callback_spy).was.called(1)
                local timeout_call = assert.not_nil(callback_spy.calls[1])
                assert.is_nil(timeout_call[1])
                assert.equal(
                    ACPClient.ERROR_CODES.TIMEOUT_ERROR,
                    timeout_call[2].code
                )
                assert.is_nil(client.callbacks[1])

                client:_handle_message({
                    jsonrpc = "2.0",
                    id = 1,
                    result = { ok = true },
                })

                assert.spy(callback_spy).was.called(1)
                assert.spy(notify_stub).was.called(0)
            end
        )
    end)
end)
