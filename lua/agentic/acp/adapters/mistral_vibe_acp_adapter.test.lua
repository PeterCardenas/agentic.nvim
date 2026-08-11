--- @diagnostic disable: access-invisible, missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local MistralVibeACPAdapter =
    require("agentic.acp.adapters.mistral_vibe_acp_adapter")

local function new_adapter()
    -- The constructor starts a provider transport, so these unit tests use
    -- the same initialized instance shape as ACP adapter tests elsewhere.
    return setmetatable({
        provider_config = {},
        subscribers = {},
        callbacks = {},
        _raw_output_deltas = {},
        _tool_call_states = {},
    }, MistralVibeACPAdapter)
end

local function new_handlers(messages)
    return {
        on_session_update = function() end,
        on_request_permission = function() end,
        on_tool_call = function() end,
        on_tool_call_update = function(message)
            table.insert(messages, message)
        end,
        on_error = function() end,
    }
end

local function update(id, raw_output, status, content)
    local result = {
        sessionUpdate = "tool_call_update",
        toolCallId = id,
        status = status or "in_progress",
        content = content and {
            {
                type = "content",
                content = { type = "text", text = content },
            },
        } or nil,
    }

    if raw_output ~= nil then
        result.rawOutput = vim.json.encode(raw_output)
    end

    return result
end

describe("agentic.acp.adapters.MistralVibeACPAdapter", function()
    it(
        "aggregates realistic raw output deltas through the public update dispatch",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            adapter:__handle_tool_call_update(
                "session",
                update("stdout", { stdout = "first line\n" })
            )
            local delivered = vim.wait(1000, function()
                return #messages == 1
            end, 10)
            assert.is_true(delivered)

            adapter:__handle_tool_call_update(
                "session",
                update("stdout", { stdout = "second line\n" })
            )
            delivered = vim.wait(1000, function()
                return #messages == 2
            end, 10)
            assert.is_true(delivered)

            assert.same({ "first line", "" }, messages[1].body)
            local latest = assert.not_nil(messages[2]).body
            assert.same({
                "first line",
                "",
                "",
                "---",
                "",
                "second line",
                "",
            }, latest)
        end
    )

    it(
        "aggregates stderr-only and combined raw output through public dispatch",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            adapter:__handle_tool_call_update(
                "session",
                update("output", { stderr = "warning\n" })
            )
            adapter:__handle_tool_call_update(
                "session",
                update("output", {
                    stdout = "output\n",
                    stderr = "warning\n",
                })
            )

            assert.is_true(vim.wait(1000, function()
                return #messages == 2
            end, 10))
            assert.same({ "warning", "" }, messages[1].body)
            assert.same({
                "warning",
                "",
                "---",
                "",
                "output",
                "",
                "warning",
                "",
            }, messages[2].body)
        end
    )

    it("aggregates repeated response and matches snapshots", function()
        local adapter = new_adapter()
        local _response = adapter:__build_tool_call_update(
            update("response", { response = "one", turns_used = 1 })
        ).body
        local latest_response = adapter:__build_tool_call_update(
            update("response", { response = "two", turns_used = 2 })
        ).body
        local _matches = adapter:__build_tool_call_update(
            update("matches", { matches = "a" })
        ).body
        local latest_matches = adapter:__build_tool_call_update(
            update("matches", { matches = "b" })
        ).body

        assert.same({ "one", "", "---", "", "two" }, latest_response)
        assert.same({ "a", "", "---", "", "b" }, latest_matches)
    end)

    it("keeps benign empty and malformed raw output behavior", function()
        local adapter = new_adapter()
        local empty = adapter:__build_tool_call_update(
            update("empty", {}, nil, "existing")
        ).body
        local malformed = adapter:__build_tool_call_update({
            sessionUpdate = "tool_call_update",
            toolCallId = "empty",
            status = "in_progress",
            rawOutput = "not json",
            content = {
                {
                    type = "content",
                    content = { type = "text", text = "existing" },
                },
            },
        }).body

        assert.same({ "existing" }, empty)
        assert.same({ "existing" }, malformed)
    end)

    it(
        "preserves the raw aggregate when a terminal update has standard content",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            adapter:__handle_tool_call_update(
                "session",
                update("terminal", { stdout = "raw output" })
            )
            adapter:__handle_tool_call_update(
                "session",
                update("terminal", "not json", "completed", "standard content")
            )

            assert.is_true(vim.wait(1000, function()
                return #messages == 2
            end, 10))
            assert.same({ "raw output" }, messages[2].body)

            local fresh = adapter:__build_tool_call_update(
                update("terminal", { stdout = "fresh output" })
            )
            assert.same({ "fresh output" }, fresh.body)
        end
    )

    it(
        "preserves the raw aggregate when a terminal update has no content",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            adapter:__handle_tool_call_update(
                "session",
                update("terminal", { stdout = "raw output" })
            )
            adapter:__handle_tool_call_update(
                "session",
                update("terminal", nil, "completed")
            )

            assert.is_true(vim.wait(1000, function()
                return #messages == 2
            end, 10))
            assert.same({ "raw output" }, messages[2].body)
        end
    )

    it("does not index decoded non-object raw output", function()
        local adapter = new_adapter()
        local message = adapter:__build_tool_call_update({
            sessionUpdate = "tool_call_update",
            toolCallId = "scalar",
            status = "in_progress",
            rawOutput = vim.json.encode("not an object"),
        })

        assert.is_nil(message.body)
    end)

    it("rejects updates with a missing or invalid tool call ID", function()
        local adapter = new_adapter()
        local messages = {}
        adapter.subscribers.session = new_handlers(messages)

        local malformed_updates = {
            update("valid", { stdout = "should be ignored" }),
            update("valid", { stdout = "should be ignored" }),
            update("valid", { stdout = "should be ignored" }),
        }
        malformed_updates[1].toolCallId = nil
        malformed_updates[2].toolCallId = 42
        malformed_updates[3].toolCallId = ""
        for _, malformed in ipairs(malformed_updates) do
            assert.has_no_errors(function()
                adapter:__handle_tool_call_update("session", malformed)
            end)
        end

        assert.equal(0, #messages)
        assert.is_nil(adapter._raw_output_deltas.session)
    end)

    it("does not let empty raw streams replace standard content", function()
        local adapter = new_adapter()
        local message = adapter:__build_tool_call_update(
            update(
                "empty-stream",
                { stdout = "", stderr = "" },
                nil,
                "standard"
            )
        )

        assert.same({ "standard" }, message.body)
        assert.is_nil(adapter._raw_output_deltas.__direct__)
    end)

    it(
        "ignores late updates after terminal status until a new tool call",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            local function dispatch(update_value)
                adapter:__handle_tool_call_update("session", update_value)
                assert.is_true(vim.wait(1000, function()
                    return #messages >= 1
                end, 10))
            end

            dispatch(update("reused", { stdout = "first" }))
            dispatch(update("reused", { stdout = "done" }, "completed"))
            local count_after_terminal = #messages
            adapter:__handle_tool_call_update(
                "session",
                update("reused", { stdout = "late" }, "in_progress")
            )
            vim.wait(50, function()
                return false
            end, 10)
            assert.equal(count_after_terminal, #messages)

            adapter:__handle_tool_call("session", {
                sessionUpdate = "tool_call",
                toolCallId = "reused",
                kind = "other",
                status = "pending",
                title = "new call",
            })
            dispatch(update("reused", { stdout = "fresh" }))
            assert.same({ "fresh" }, messages[#messages].body)
        end
    )

    it(
        "cleans lifecycle state when a session is stopped or cancelled",
        function()
            local adapter = new_adapter()
            adapter.transport = { send = function() end }
            adapter.subscribers.session = new_handlers({})

            adapter:__handle_tool_call_update(
                "session",
                update("stopped", { stdout = "output" })
            )
            adapter:stop_generation("session")
            assert.is_nil(adapter._raw_output_deltas.session)
            assert.is_nil(adapter._tool_call_states.session)

            adapter:__handle_tool_call_update(
                "session",
                update("cancelled", { stdout = "output" })
            )
            adapter:cancel_session("session")
            assert.is_nil(adapter._raw_output_deltas.session)
            assert.is_nil(adapter._tool_call_states.session)
        end
    )

    it(
        "keeps aggregates isolated when sessions reuse a tool call ID",
        function()
            local adapter = new_adapter()
            local messages = { first = {}, second = {} }
            adapter.subscribers.first = new_handlers(messages.first)
            adapter.subscribers.second = new_handlers(messages.second)

            adapter:__handle_tool_call_update(
                "first",
                update("shared", { stdout = "first session" })
            )
            adapter:__handle_tool_call_update(
                "second",
                update("shared", { stdout = "second session" })
            )
            adapter:__handle_tool_call_update(
                "first",
                update("shared", { stdout = "first again" })
            )

            assert.is_true(vim.wait(1000, function()
                return #messages.first == 2 and #messages.second == 1
            end, 10))
            assert.same({ "first session", "" }, messages.first[1].body)
            assert.same({
                "first session",
                "",
                "",
                "---",
                "",
                "first again",
                "",
            }, messages.first[2].body)
            assert.same({ "second session", "" }, messages.second[1].body)
        end
    )

    it(
        "does not deliver a queued update after cancellation and session reuse",
        function()
            local adapter = new_adapter()
            adapter.transport = { send = function() end }
            local messages = {}
            local handlers = new_handlers(messages)
            adapter.subscribers.session = handlers

            local queued_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(queued_callbacks, callback)
            end)

            adapter:__handle_tool_call_update(
                "session",
                update("shared", { stdout = "stale" })
            )
            adapter:cancel_session("session")
            adapter.subscribers.session = handlers

            local stale_callback = table.remove(queued_callbacks, 1)
            assert.is_not_nil(stale_callback)
            stale_callback()
            assert.equal(0, #messages)

            adapter:__handle_tool_call_update(
                "session",
                update("shared", { stdout = "fresh" })
            )
            local fresh_callback = table.remove(queued_callbacks, 1)
            assert.is_not_nil(fresh_callback)
            fresh_callback()
            schedule_stub:revert()

            assert.same({ "fresh" }, messages[1].body)
        end
    )

    it(
        "does not deliver a queued update after same-session tool ID reuse",
        function()
            local adapter = new_adapter()
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            local queued_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(queued_callbacks, callback)
            end)

            adapter:__handle_tool_call("session", {
                sessionUpdate = "tool_call",
                toolCallId = "reused",
                kind = "other",
                status = "pending",
                title = "old",
            })
            adapter:__handle_tool_call_update(
                "session",
                update("reused", { stdout = "stale" })
            )
            -- Start a replacement lifecycle before the queued stale callback
            -- runs. The old update must not reach the replacement subscriber.
            adapter:__handle_tool_call("session", {
                sessionUpdate = "tool_call",
                toolCallId = "reused",
                kind = "other",
                status = "pending",
                title = "fresh",
            })

            while #queued_callbacks > 0 do
                table.remove(queued_callbacks, 1)()
            end
            schedule_stub:revert()

            assert.equal(0, #messages)
        end
    )

    it("clears aggregates when a session is cancelled", function()
        local adapter = new_adapter()
        adapter.transport = { send = function() end }
        adapter.subscribers.session = new_handlers({})

        adapter:__handle_tool_call_update(
            "session",
            update("shared", { stdout = "before cancel" })
        )
        adapter:cancel_session("session")

        local message = adapter:__build_tool_call_update(
            update("shared", { stdout = "after cancel" }),
            "session"
        )
        assert.same({ "after cancel" }, message.body)
    end)

    it(
        "ignores a queued update stopped before delivery and delivers the next update fresh",
        function()
            local adapter = new_adapter()
            adapter.transport = { send = function() end }
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            local queued_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(queued_callbacks, callback)
            end)

            adapter:__handle_tool_call_update(
                "session",
                update("shared", { stdout = "stale" })
            )
            adapter:stop_generation("session")
            adapter:__handle_tool_call_update(
                "session",
                update("shared", { stdout = "fresh" })
            )

            local stale_callback = table.remove(queued_callbacks, 1)
            assert.is_not_nil(stale_callback)
            stale_callback()
            assert.equal(0, #messages)

            local fresh_callback = table.remove(queued_callbacks, 1)
            assert.is_not_nil(fresh_callback)
            fresh_callback()
            schedule_stub:revert()

            assert.same({ "fresh" }, messages[1].body)
        end
    )

    it(
        "ignores late updates after cancellation before a session is subscribed again",
        function()
            local adapter = new_adapter()
            adapter.transport = { send = function() end }
            local messages = {}
            adapter.subscribers.session = new_handlers(messages)

            adapter:__handle_session_update({
                sessionId = "session",
                update = update("shared", { stdout = "before cancel" }),
            })
            assert.is_true(vim.wait(1000, function()
                return #messages == 1
            end, 10))

            adapter:cancel_session("session")
            adapter:__handle_session_update({
                sessionId = "session",
                update = update("shared", { stdout = "late update" }),
            })
            assert.is_nil(adapter._raw_output_deltas.session)
            adapter.subscribers.session = new_handlers(messages)
            adapter:__handle_session_update({
                sessionId = "session",
                update = update("shared", { stdout = "fresh update" }),
            })

            assert.is_true(vim.wait(1000, function()
                return #messages == 2
            end, 10))
            assert.same({ "fresh update", "" }, messages[2].body)
        end
    )

    it("clears aggregates before stopping generation", function()
        local adapter = new_adapter()
        local notifications = {}
        adapter.transport = {
            send = function(data)
                table.insert(notifications, vim.json.decode(data))
            end,
        }
        local messages = {}
        adapter.subscribers.session = new_handlers(messages)

        adapter:__handle_session_update({
            sessionId = "session",
            update = update("shared", { stdout = "before stop" }),
        })
        assert.is_true(vim.wait(1000, function()
            return #messages == 1
        end, 10))

        adapter:stop_generation("session")
        adapter:__handle_session_update({
            sessionId = "session",
            update = update("shared", { stdout = "after stop" }),
        })

        assert.is_true(vim.wait(1000, function()
            return #messages == 2
        end, 10))
        assert.same({ "after stop", "" }, messages[2].body)
        assert.equal(1, #notifications)
        assert.equal("session/cancel", notifications[1].method)
    end)

    it("cleans terminal delta state before a tool call ID is reused", function()
        local adapter = new_adapter()
        local messages = {}
        adapter.subscribers.session = new_handlers(messages)

        local function dispatch(raw_output, id, status)
            local expected_messages = #messages + 1
            adapter:__handle_tool_call_update(
                "session",
                update(id, raw_output, status)
            )
            local delivered = vim.wait(1000, function()
                return #messages >= expected_messages
            end, 10)
            assert.is_true(delivered)
        end

        for _, terminal_status in ipairs({ "completed", "failed", "cancelled" }) do
            local id = "reused-" .. terminal_status
            dispatch({ stdout = "before" }, id)
            dispatch({ stdout = "terminal" }, id, terminal_status)
            dispatch({ stdout = "fresh" }, id)

            local latest = assert.not_nil(messages[#messages]).body
            assert.same({ "fresh" }, latest)
        end
    end)
end)
