--- @diagnostic disable: access-invisible, missing-fields
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local CursorACPAdapter = require("agentic.acp.adapters.cursor_acp_adapter")

--- @return agentic.acp.CursorACPAdapter
local function new_adapter()
    --- @type agentic.acp.CursorACPAdapter
    local adapter = setmetatable({
        provider_config = {
            name = "Cursor ACP",
            command = "cursor-agent-acp",
        },
        subscribers = {},
        callbacks = {},
        _available_commands_updates = {},
        _chunk_stream_started = {},
        _task_tool_inputs = {},
        _task_tool_sessions = {},
        transport = {
            send = function()
                return true
            end,
        },
    }, CursorACPAdapter)

    return adapter
end

--- @return agentic.acp.ClientHandlers handlers
--- @return TestSpy on_tool_call
--- @return TestSpy on_tool_call_update
local function new_handlers()
    local on_session_update = spy.new(function() end)
    local on_request_permission = spy.new(function() end)
    local on_error = spy.new(function() end)
    local on_tool_call = spy.new(function() end)
    local on_tool_call_update = spy.new(function() end)

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_session_update = on_session_update,
        on_request_permission = on_request_permission,
        on_error = on_error,
        on_tool_call = on_tool_call,
        on_tool_call_update = on_tool_call_update,
    }

    return handlers, on_tool_call, on_tool_call_update
end

--- @param fn fun()
local function run_in_fast_event(fn)
    local timer = assert.not_nil(vim.uv.new_timer())
    local done = false
    local ok = false
    local err

    timer:start(0, 0, function()
        assert.is_true(vim.in_fast_event())
        ok, err = xpcall(fn, debug.traceback)
        done = true
        timer:stop()
        timer:close()
    end)

    local completed = vim.wait(1000, function()
        return done
    end, 10)
    assert.is_true(completed)

    if not ok then
        error(err)
    end
end

describe("agentic.acp.adapters.CursorACPAdapter", function()
    it("preserves markdown across interleaved usage updates", function()
        local adapter = new_adapter()
        local handlers = new_handlers()
        adapter.subscribers["session-1"] = handlers

        local rendered_chunks = {}
        for _, text in ipairs({
            "\n\nHere is the Lua code.",
            "\n",
            "\n",
            "```",
            "lua",
            "\n",
            "local x = 1",
            "\n",
            "print(x)",
            "\n",
            "```",
            "\n",
            "\n",
            "It prints the value of x.",
        }) do
            local chunk = {
                sessionUpdate = "agent_message_chunk",
                content = { type = "text", text = text },
            }
            adapter:__handle_session_update({
                sessionId = "session-1",
                update = chunk,
            })
            table.insert(rendered_chunks, chunk.content.text)
            adapter:__handle_session_update({
                sessionId = "session-1",
                update = { sessionUpdate = "usage_update" },
            })
        end

        assert.equal(
            table.concat({
                "Here is the Lua code.",
                "",
                "```lua",
                "local x = 1",
                "print(x)",
                "```",
                "",
                "It prints the value of x.",
            }, "\n"),
            table.concat(rendered_chunks)
        )
    end)

    it("formats read arguments with line ranges", function()
        local adapter = new_adapter()
        local argument

        run_in_fast_event(function()
            argument = adapter:_format_read_argument({
                file_path = "/tmp/example.lua",
                line = 10,
                limit = 5,
            }, nil)
        end)

        assert.equal("/tmp/example.lua:10-14", argument)
    end)

    it("formats read offsets as 1-indexed line ranges", function()
        local adapter = new_adapter()
        local argument

        run_in_fast_event(function()
            argument = adapter:_format_read_argument({
                file_path = "/tmp/example.lua",
                offset = 35,
                limit = 20,
            }, nil)
        end)

        assert.equal("/tmp/example.lua:36-55", argument)
    end)

    it("formats search arguments from query and path metadata", function()
        local adapter = new_adapter()
        local argument

        run_in_fast_event(function()
            argument = adapter:_format_search_argument({
                query = "MessageWriter",
                path = "/tmp/project",
                glob = "*.lua",
            }, nil)
        end)

        assert.equal("MessageWriter path=/tmp/project glob=*.lua", argument)
    end)

    it("formats search cwd paths as dot", function()
        local adapter = new_adapter()
        local argument
        local cwd_stub = spy.stub(vim.uv, "cwd")
        cwd_stub:returns("/tmp/project")

        run_in_fast_event(function()
            argument = adapter:_format_search_argument({
                query = "MessageWriter",
                path = "/tmp/project",
                glob = "*.lua",
            }, nil)
        end)

        assert.equal("MessageWriter path=. glob=*.lua", argument)
        cwd_stub:revert()
    end)

    it("strips duplicated kind from fallback read title", function()
        local adapter = new_adapter()
        local argument

        run_in_fast_event(function()
            argument = adapter:_format_read_argument(nil, "Read lua/init.lua")
        end)

        assert.equal("lua/init.lua", argument)
    end)

    it(
        "strips duplicated kind and backticks from fallback edit title",
        function()
            local adapter = new_adapter()
            local handlers, on_tool_call = new_handlers()
            adapter.subscribers["session-1"] = handlers

            run_in_fast_event(function()
                adapter:_handle_message({
                    jsonrpc = "2.0",
                    method = "session/update",
                    params = {
                        sessionId = "session-1",
                        update = {
                            sessionUpdate = "tool_call",
                            toolCallId = "tool-1",
                            kind = "edit",
                            status = "pending",
                            title = "Edit `lua/init.lua:1-2`",
                        },
                    },
                })
            end)

            local notified = vim.wait(1000, function()
                return on_tool_call.call_count == 1
            end, 10)
            assert.is_true(notified)

            local call_args = assert.not_nil(on_tool_call.calls[1])
            local message = assert.not_nil(call_args[1])
            assert.equal("lua/init.lua:1-2", message.argument)
        end
    )

    it("does not build edit diff when raw input has no diff payload", function()
        local adapter = new_adapter()
        local diff

        run_in_fast_event(function()
            diff = adapter:_build_edit_diff({
                file_path = "/tmp/example.lua",
            })
        end)

        assert.is_nil(diff)
    end)

    it("builds edit diff when new content is present", function()
        local adapter = new_adapter()
        local diff

        run_in_fast_event(function()
            diff = adapter:_build_edit_diff({
                file_path = "/tmp/example.lua",
                new_string = "new content",
                old_string = "old content",
            })
        end)

        assert.is_not_nil(diff)
        local resolved_diff = assert.not_nil(diff)
        assert.same({ "new content" }, resolved_diff.new)
        assert.same({ "old content" }, resolved_diff.old)
    end)

    it("handles tool_call notifications from fast events", function()
        local adapter = new_adapter()
        local handlers, on_tool_call = new_handlers()
        adapter.subscribers["session-1"] = handlers

        run_in_fast_event(function()
            adapter:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = {
                    sessionId = "session-1",
                    update = {
                        sessionUpdate = "tool_call",
                        toolCallId = "tool-1",
                        kind = "read",
                        status = "completed",
                        title = "Read lua/init.lua",
                        rawInput = {
                            file_path = "/tmp/example.lua",
                            line = 10,
                            limit = 5,
                        },
                    },
                },
            })
        end)

        local notified = vim.wait(1000, function()
            return on_tool_call.call_count == 1
        end, 10)
        assert.is_true(notified)

        local call_args = assert.not_nil(on_tool_call.calls[1])
        local message = assert.not_nil(call_args[1])
        assert.equal("tool-1", message.tool_call_id)
        assert.equal("/tmp/example.lua:10-14", message.argument)
    end)

    it("formats edit tool calls with line ranges", function()
        local adapter = new_adapter()
        local handlers, on_tool_call = new_handlers()
        adapter.subscribers["session-1"] = handlers

        run_in_fast_event(function()
            adapter:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = {
                    sessionId = "session-1",
                    update = {
                        sessionUpdate = "tool_call",
                        toolCallId = "tool-1",
                        kind = "edit",
                        status = "pending",
                        title = "Edit /tmp/example.lua",
                        rawInput = {
                            file_path = "/tmp/example.lua",
                            start_line = 3,
                            end_line = 4,
                            old_string = "old content",
                            new_string = "new content",
                        },
                    },
                },
            })
        end)

        local notified = vim.wait(1000, function()
            return on_tool_call.call_count == 1
        end, 10)
        assert.is_true(notified)

        local call_args = assert.not_nil(on_tool_call.calls[1])
        local message = assert.not_nil(call_args[1])
        assert.equal("tool-1", message.tool_call_id)
        assert.equal("/tmp/example.lua:3-4", message.argument)
    end)

    it("handles tool_call_update notifications from fast events", function()
        local adapter = new_adapter()
        local handlers, _, on_tool_call_update = new_handlers()
        adapter.subscribers["session-1"] = handlers

        run_in_fast_event(function()
            adapter:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = {
                    sessionId = "session-1",
                    update = {
                        sessionUpdate = "tool_call_update",
                        toolCallId = "tool-1",
                        kind = "search",
                        status = "completed",
                        title = "Search MessageWriter",
                        rawInput = {
                            query = "MessageWriter",
                            path = "/tmp/project",
                            glob = "*.lua",
                        },
                        rawOutput = {
                            totalFiles = 3,
                            truncated = true,
                        },
                    },
                },
            })
        end)

        local notified = vim.wait(1000, function()
            return on_tool_call_update.call_count == 1
        end, 10)
        assert.is_true(notified)

        local call_args = assert.not_nil(on_tool_call_update.calls[1])
        local message = assert.not_nil(call_args[1])
        assert.equal("tool-1", message.tool_call_id)
        assert.equal(
            "MessageWriter path=/tmp/project glob=*.lua",
            message.argument
        )
        assert.same({ "Found 3 file(s) (truncated)" }, message.body)
    end)

    it("builds a rich completion body from cursor/task", function()
        local adapter = new_adapter()
        local handlers, on_tool_call, on_tool_call_update = new_handlers()
        adapter.subscribers["session-1"] = handlers

        run_in_fast_event(function()
            adapter:_handle_message({
                jsonrpc = "2.0",
                method = "session/update",
                params = {
                    sessionId = "session-1",
                    update = {
                        sessionUpdate = "tool_call",
                        toolCallId = "tool-task-2b",
                        kind = "other",
                        status = "pending",
                        title = "Task: Subagent task",
                        rawInput = {
                            _toolName = "task",
                            description = "Subagent returns SUBAGENT_OK",
                            prompt = "Reply with exactly SUBAGENT_OK",
                        },
                    },
                },
            })
            adapter:_handle_message({
                jsonrpc = "2.0",
                id = 9,
                method = "cursor/task",
                params = {
                    toolCallId = "tool-task-2b",
                    description = "Subagent returns SUBAGENT_OK",
                    prompt = "Reply with exactly SUBAGENT_OK",
                    finalMessage = "SUBAGENT_OK",
                    durationMs = 850,
                    model = "composer-2-fast",
                    subagentType = {
                        custom = {
                            unspecified = {},
                        },
                    },
                },
            })
        end)

        local tool_call_notified = vim.wait(1000, function()
            return on_tool_call.call_count == 1
        end, 10)
        assert.is_true(tool_call_notified)

        local tool_call_args = assert.not_nil(on_tool_call.calls[1])
        local tool_call_message = assert.not_nil(tool_call_args[1])
        assert.is_nil(tool_call_message.body)

        local update_notified = vim.wait(1000, function()
            return on_tool_call_update.call_count == 1
        end, 10)
        assert.is_true(update_notified)

        local call_args = assert.not_nil(on_tool_call_update.calls[1])
        local message = assert.not_nil(call_args[1])
        assert.equal("tool-task-2b", message.tool_call_id)
        assert.equal("SubAgent", message.kind)
        assert.same({
            "Prompt:",
            "Reply with exactly SUBAGENT_OK",
            "",
            "Final message:",
            "SUBAGENT_OK",
        }, message.body)
    end)

    it("clears retained task raw input after terminal task update", function()
        local adapter = new_adapter()
        adapter._task_tool_inputs["tool-task-done"] = {
            _toolName = "task",
            description = "Subagent returns OK",
            prompt = "Reply OK",
        }

        adapter:__build_tool_call_update({
            sessionUpdate = "tool_call_update",
            toolCallId = "tool-task-done",
            status = "completed",
            rawOutput = {
                finalMessage = "OK",
            },
        })

        assert.is_nil(adapter._task_tool_inputs["tool-task-done"])
    end)

    it("clears only the cancelled session's retained task inputs", function()
        local adapter = new_adapter()
        adapter.subscribers["session-1"] = new_handlers()
        adapter.subscribers["session-2"] = new_handlers()

        adapter:__handle_tool_call("session-1", {
            sessionUpdate = "tool_call",
            toolCallId = "tool-task-1",
            kind = "other",
            status = "pending",
            title = "Task one",
            rawInput = {
                _toolName = "task",
                description = "Task one",
                prompt = "one",
            },
        })
        adapter:__handle_tool_call("session-2", {
            sessionUpdate = "tool_call",
            toolCallId = "tool-task-2",
            kind = "other",
            status = "pending",
            title = "Task two",
            rawInput = {
                _toolName = "task",
                description = "Task two",
                prompt = "two",
            },
        })

        adapter:cancel_session("session-1")

        assert.is_nil(adapter._task_tool_inputs["tool-task-1"])
        assert.is_not_nil(adapter._task_tool_inputs["tool-task-2"])
    end)
end)
