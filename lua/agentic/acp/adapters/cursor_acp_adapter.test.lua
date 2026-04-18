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

    it("strips duplicated kind from fallback read title", function()
        local adapter = new_adapter()
        local argument

        run_in_fast_event(function()
            argument = adapter:_format_read_argument(nil, "Read lua/init.lua")
        end)

        assert.equal("lua/init.lua", argument)
    end)

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
end)
