--- @diagnostic disable: redundant-parameter, cast-local-type, unresolved-require
local assert = require("tests.helpers.assert")
local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local SESSION_ID = "mock-session-001"
local root_dir = vim.fn.getcwd()

--- Set up child with the full mock transport that completes the ACP handshake.
local function setup_child()
    child.restart({ "-u", "NONE" })
    child.lua("vim.opt.rtp:prepend(...)", { root_dir })

    child.lua([[
        local mock = require("tests.mocks.acp_transport_full_mock")
        package.loaded["agentic.acp.acp_transport"] = mock

        local ACPHealthMock = require("tests.mocks.acp_health_mock")
        package.loaded["agentic.acp.acp_health"] = ACPHealthMock
    ]])

    child.lua([[
        local Config = require("agentic.config")
        Config.session_restore.storage_path = vim.fn.tempname()
        vim.fn.mkdir(Config.session_restore.storage_path, "p")
        require("agentic").setup()
    ]])
end

--- Open the widget and wait for session to initialize.
--- Returns the session manager (accessed via lua_get).
local function open_widget_and_wait()
    child.lua([[ require("agentic").toggle() ]])

    -- Flush scheduled callbacks (session creation is deferred)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(100)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(100)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

--- Get the chat buffer content as a single string.
--- @return string
local function get_chat_content()
    return child.lua([[
        local tab_id = vim.api.nvim_get_current_tabpage()
        local session = require("agentic.session_registry").sessions[tab_id]
        if not session then return "" end
        local bufnr = session.widget.buf_nrs.chat
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        return table.concat(lines, "\n")
    ]])
end

--- Submit a prompt by writing to the input buffer and triggering submit.
--- @param text string
local function submit_prompt(text)
    child.lua(string.format(
        [[
        local tab_id = vim.api.nvim_get_current_tabpage()
        local session = require("agentic.session_registry").sessions[tab_id]
        local input_bufnr = session.widget.buf_nrs.input
        vim.api.nvim_buf_set_lines(input_bufnr, 0, -1, false, {%q})
        session.widget:_submit_input()
    ]],
        text
    ))

    -- Flush
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

--- Complete the pending prompt (simulate turn end).
local function complete_prompt()
    child.lua([[
        local transport = require("tests.mocks.acp_transport_full_mock").instance
        transport:complete_prompt("end_turn")
    ]])

    -- Flush scheduled callbacks
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(50)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

--- Inject a tool_call notification (Phase 1 - initial tool call).
--- @param tool_call_id string
--- @param kind string
--- @param title string
local function inject_tool_call(tool_call_id, kind, title)
    child.lua(string.format(
        [[
        local transport = require("tests.mocks.acp_transport_full_mock").instance
        transport:inject_notification(%q, {
            sessionUpdate = "tool_call",
            toolCallId = %q,
            kind = %q,
            title = %q,
            status = "running",
        })
    ]],
        SESSION_ID,
        tool_call_id,
        kind,
        title
    ))

    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

--- Inject a tool_call_update notification (Phase 2 - update with rawInput).
--- @param tool_call_id string
--- @param status string
--- @param raw_input_fields string Lua table literal for rawInput fields
--- @param kind string|nil
--- @param title string|nil
local function inject_tool_call_update(
    tool_call_id,
    status,
    raw_input_fields,
    kind,
    title
)
    local kind_field = kind and string.format("kind = %q,", kind) or ""
    local title_field = title and string.format("title = %q,", title) or ""

    child.lua(
        string.format(
            [[
        local transport = require("tests.mocks.acp_transport_full_mock").instance
        transport:inject_notification(%q, {
            sessionUpdate = "tool_call_update",
            toolCallId = %q,
            status = %q,
            %s
            %s
            rawInput = %s,
            content = {
                { type = "content", content = { type = "text", text = "command output" } },
            },
        })
    ]],
            SESSION_ID,
            tool_call_id,
            status,
            kind_field,
            title_field,
            raw_input_fields
        )
    )

    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

--- Get the chat history messages from the current session.
--- @return table[]
local function get_chat_history_messages()
    return child.lua([[
        local tab_id = vim.api.nvim_get_current_tabpage()
        local session = require("agentic.session_registry").sessions[tab_id]
        if not session then return {} end
        local ChatHistory = require("agentic.ui.chat_history")
        session.chat_history:save(function() end)
        return ChatHistory.collect_messages(session.chat_history:get_replay_source())
    ]])
end

describe("Tool call - enriched argument preserved in chat history", function()
    before_each(function()
        setup_child()
    end)

    after_each(function()
        child.lua([[
            local Config = require("agentic.config")
            vim.fn.delete(Config.session_restore.storage_path, "rf")
        ]])
        child.stop()
    end)

    it(
        "execute tool call stores command from tool_call_update rawInput",
        function()
            open_widget_and_wait()

            submit_prompt("Run npm test")
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Phase 1: tool_call with generic title
            inject_tool_call("tool-exec-001", "execute", "Terminal")

            -- Phase 2: tool_call_update with rawInput.command (claude-agent-acp style)
            inject_tool_call_update(
                "tool-exec-001",
                "completed",
                '{ command = "npm test" }',
                "execute",
                "Terminal"
            )
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Chat buffer should show the actual command, not "Terminal"
            local content = get_chat_content()
            assert.truthy(
                content:find("npm test"),
                "Chat should show actual command 'npm test', got:\n" .. content
            )

            -- Chat history should store enriched argument
            local messages = get_chat_history_messages()
            --- @type agentic.ui.ChatHistory.ToolCall|nil
            local tool_msg = nil
            for i = #messages, 1, -1 do
                local candidate = messages[i]
                if
                    candidate.type == "tool_call"
                    and candidate.tool_call_id == "tool-exec-001"
                then
                    --- @cast candidate agentic.ui.ChatHistory.ToolCall
                    tool_msg = candidate
                    break
                end
            end

            assert.is_not_nil(
                tool_msg,
                "Tool call message should exist in chat history"
            )
            assert.equal(
                "npm test",
                --- @diagnostic disable-next-line: need-check-nil
                tool_msg.argument,
                "Chat history argument should be 'npm test', not 'Terminal'"
            )
        end
    )

    it(
        "edit tool call stores file path from tool_call_update rawInput",
        function()
            open_widget_and_wait()

            submit_prompt("Edit a file")
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Phase 1: tool_call with generic title
            inject_tool_call("tool-edit-001", "edit", "Write")

            -- Phase 2: tool_call_update with rawInput file_path (claude-agent-acp style)
            inject_tool_call_update(
                "tool-edit-001",
                "completed",
                '{ file_path = "/tmp/test.lua", new_string = "print(1)" }',
                "edit",
                "Write"
            )
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Chat history should store enriched argument (file path, not "Write")
            local messages = get_chat_history_messages()
            --- @type agentic.ui.ChatHistory.ToolCall|nil
            local tool_msg = nil
            for i = #messages, 1, -1 do
                local candidate = messages[i]
                if
                    candidate.type == "tool_call"
                    and candidate.tool_call_id == "tool-edit-001"
                then
                    --- @cast candidate agentic.ui.ChatHistory.ToolCall
                    tool_msg = candidate
                    break
                end
            end

            assert.is_not_nil(
                tool_msg,
                "Tool call message should exist in chat history"
            )
            assert.are_not.equal(
                "Write",
                --- @diagnostic disable-next-line: need-check-nil
                tool_msg.argument,
                "Chat history should NOT have generic title 'Write'"
            )
        end
    )

    it(
        "restored session displays enriched argument, not generic title",
        function()
            open_widget_and_wait()

            submit_prompt("Run tests")
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Simulate execute tool call lifecycle
            inject_tool_call("tool-restore-001", "execute", "Terminal")
            inject_tool_call_update(
                "tool-restore-001",
                "completed",
                '{ command = "make test" }',
                "execute",
                "Terminal"
            )
            vim.uv.sleep(50)
            child.lua([[ vim.cmd("redraw") ]])
            child.api.nvim_eval("1")

            -- Complete the turn
            complete_prompt()

            -- Get messages from chat history, then replay them into a fresh buffer
            local restored_content = child.lua([[
                local tab_id = vim.api.nvim_get_current_tabpage()
                local session = require("agentic.session_registry").sessions[tab_id]
                local source = session.chat_history:get_replay_source()

                -- Create a fresh buffer and message writer to simulate restore
                local MessageWriter = require("agentic.ui.message_writer")
                local fresh_buf = vim.api.nvim_create_buf(false, true)
                vim.bo[fresh_buf].modifiable = true
                local writer = MessageWriter:new(fresh_buf)

                local SessionRestore = require("agentic.session_restore")
                SessionRestore.replay_messages_from_source(writer, source)

                local lines = vim.api.nvim_buf_get_lines(fresh_buf, 0, -1, false)
                vim.api.nvim_buf_delete(fresh_buf, { force = true })
                return table.concat(lines, "\n")
            ]])

            assert.truthy(
                restored_content:find("make test"),
                "Restored session should show 'make test', not 'Terminal', got:\n"
                    .. restored_content
            )
            assert.is_falsy(
                restored_content:find("execute%(Terminal%)"),
                "Restored session should NOT show 'execute(Terminal)', got:\n"
                    .. restored_content
            )
        end
    )
end)

--- Return persistence state from the child Neovim process.
local function get_persistence_state()
    return child.lua([[
        local ChatHistory = require("agentic.ui.chat_history")
        local folder = ChatHistory.get_sessions_folder()
        local jsonl = ChatHistory.get_jsonl_file_path("mock-session-001")
        local metadata = ChatHistory.get_metadata_file_path("mock-session-001")
        local listed = {}
        ChatHistory.list_sessions(function(sessions)
            for _, session in ipairs(sessions) do
                table.insert(listed, session.session_id)
            end
        end, folder)
        local records = {}
        local file = io.open(jsonl, "r")
        if file then
            for line in file:lines() do
                table.insert(records, vim.json.decode(line))
            end
            file:close()
        end
        return {
            jsonl = vim.uv.fs_stat(jsonl) ~= nil,
            metadata = vim.uv.fs_stat(metadata) ~= nil,
            listed = listed,
            records = records,
        }
    ]])
end

describe("ChatHistory persistence lifecycle", function()
    before_each(function()
        setup_child()
    end)

    after_each(function()
        child.lua([[
            local Config = require("agentic.config")
            vim.fn.delete(Config.session_restore.storage_path, "rf")
        ]])
        child.stop()
    end)

    it(
        "does not persist a newly created session or agent-only event",
        function()
            open_widget_and_wait()

            local initial = get_persistence_state()
            assert.is_false(initial.jsonl)
            assert.is_false(initial.metadata)
            assert.equal(0, #initial.listed)

            inject_tool_call("tool-before-prompt", "execute", "Terminal")
            local after_event = get_persistence_state()
            assert.is_false(after_event.jsonl)
            assert.is_false(after_event.metadata)
            assert.equal(0, #after_event.listed)
        end
    )

    it("persists the user record before response and turn records", function()
        open_widget_and_wait()
        inject_tool_call("tool-before-prompt", "execute", "Terminal")
        submit_prompt("hello")
        complete_prompt()
        vim.uv.sleep(100)
        child.lua([[ vim.cmd("redraw") ]])
        child.api.nvim_eval("1")

        local state = get_persistence_state()
        assert.is_true(state.jsonl)
        assert.is_true(state.metadata)
        assert.equal(1, #state.listed)
        assert.equal(SESSION_ID, state.listed[1])
        assert.equal(3, #state.records)
        assert.equal("message", state.records[1].type)
        assert.equal("tool_call", state.records[1].message.type)
        assert.equal("message", state.records[2].type)
        assert.equal("user", state.records[2].message.type)
        assert.equal("hello", state.records[2].message.text)
        assert.equal("message", state.records[3].type)
        assert.equal("turn_end", state.records[3].message.type)
    end)
end)
