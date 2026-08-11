--- @diagnostic disable: invisible, redundant-parameter
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local ACPClient = require("agentic.acp.acp_client")
local Logger = require("agentic.utils.logger")

---@diagnostic disable: access-invisible, missing-fields, param-type-mismatch

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
    it(
        "responds to queued permissions when a soft stop invalidates delivery",
        function()
            local sent_messages = {}
            local client = new_client()
            client.transport.send = function(...)
                local data = select(2, ...)
                table.insert(
                    sent_messages,
                    type(data) == "string" and vim.json.decode(data) or data
                )
            end

            local scheduled_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(scheduled_callbacks, callback)
            end)

            local session_updates = 0
            local permission_requests = 0
            local permission_callback
            local handlers = {
                on_session_update = function()
                    session_updates = session_updates + 1
                end,
                on_request_permission = function(_, callback)
                    permission_requests = permission_requests + 1
                    permission_callback = callback
                end,
            }
            client:_subscribe("session-1", handlers)
            client:__handle_session_update({
                sessionId = "session-1",
                update = { sessionUpdate = "current_mode_update" },
            })
            client:__handle_request_permission(1, {
                sessionId = "session-1",
                toolCall = { toolCallId = "tool-1", title = "read" },
            })

            client:stop_generation("session-1")

            client:__handle_session_update({
                sessionId = "session-1",
                update = { sessionUpdate = "next_turn_update" },
            })

            for _, callback in ipairs(scheduled_callbacks) do
                callback()
            end
            schedule_stub:revert()

            assert.equal(1, session_updates)
            assert.equal(0, permission_requests)
            assert.is_nil(permission_callback)

            local responses = vim.tbl_filter(function(message)
                return message.result ~= nil
            end, sent_messages)
            assert.equal(1, #responses)
            assert.same(
                { outcome = { outcome = "cancelled" } },
                responses[1].result
            )
        end
    )

    it(
        "responds to a queued permission when the session is cancelled",
        function()
            local sent_messages = {}
            local client = new_client()
            client.transport.send = function(...)
                table.insert(sent_messages, select(2, ...))
            end

            local scheduled_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(scheduled_callbacks, callback)
            end)

            client:_subscribe("session-1", {
                on_request_permission = function()
                    error("cancelled permission must not be delivered")
                end,
            })
            client:__handle_request_permission(8, {
                sessionId = "session-1",
                toolCall = { toolCallId = "tool-1", title = "read" },
            })
            client:cancel_session("session-1")

            for _, callback in ipairs(scheduled_callbacks) do
                callback()
            end
            schedule_stub:revert()

            local response = vim.json.decode(sent_messages[2])
            assert.equal(8, response.id)
            assert.same(
                { outcome = { outcome = "cancelled" } },
                response.result
            )
        end
    )

    it(
        "cancels a permission immediately when its subscriber is already gone",
        function()
            local sent_messages = {}
            local client = new_client()
            client.transport.send = function(_, data)
                table.insert(sent_messages, vim.json.decode(data))
            end

            client:__handle_request_permission(11, {
                sessionId = "missing-session",
                toolCall = { toolCallId = "tool-1", title = "read" },
            })

            assert.equal(1, #sent_messages)
            assert.equal(11, sent_messages[1].id)
            assert.same(
                { outcome = { outcome = "cancelled" } },
                sent_messages[1].result
            )
        end
    )

    it(
        "responds exactly once after cancellation even if selected later",
        function()
            local sent_messages = {}
            local client = new_client()
            client.transport.send = function(...)
                local data = select(2, ...)
                table.insert(
                    sent_messages,
                    type(data) == "string" and vim.json.decode(data) or data
                )
            end

            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                callback()
            end)

            local permission_callback
            client:_subscribe("session-1", {
                on_request_permission = function(_, callback)
                    permission_callback = callback
                end,
            })
            client:__handle_request_permission(7, {
                sessionId = "session-1",
                toolCall = { toolCallId = "tool-1", title = "read" },
            })

            local callback = assert.not_nil(permission_callback)
            callback(nil)
            callback("allow_once")
            schedule_stub:revert()

            local responses = vim.tbl_filter(function(message)
                return message.result ~= nil
            end, sent_messages)
            assert.equal(1, #responses)
            assert.same(
                { outcome = { outcome = "cancelled" } },
                responses[1].result
            )
        end
    )

    describe("generic tool content extraction", function()
        it(
            "distinguishes omitted content from an explicit empty collection",
            function()
                local client = new_client()

                assert.is_nil(client:extract_content_body({
                    toolCallId = "omitted",
                }))
                assert.same(
                    {},
                    client:extract_content_body({
                        toolCallId = "empty",
                        content = {},
                    })
                )
            end
        )
    end)

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
