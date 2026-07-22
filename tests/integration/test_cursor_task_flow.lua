--- @diagnostic disable: redundant-parameter, cast-local-type, unresolved-require
local assert = require("tests.helpers.assert")
local MiniTest = require("mini.test")
local child = MiniTest.new_child_neovim()

local SESSION_ID = "mock-session-001"
local root_dir = vim.fn.getcwd()

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
        require("agentic").setup({
            provider = "cursor-acp",
            acp_providers = {
                ["cursor-acp"] = {
                    name = "Cursor ACP",
                    command = "agent",
                    args = { "acp" },
                    env = {},
                    auth_method = false,
                },
            },
        })
    ]])
end

local function open_widget_and_wait()
    child.lua([[ require("agentic").toggle() ]])
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(100)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(100)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

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

    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

local function complete_prompt()
    child.lua([[
        local transport = require("tests.mocks.acp_transport_full_mock").instance
        transport:complete_prompt("end_turn")
    ]])

    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
    vim.uv.sleep(50)
    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

local function inject_cursor_task(params_literal)
    child.lua(string.format(
        [[
        local transport = require("tests.mocks.acp_transport_full_mock").instance
        transport._callbacks.on_message({
            jsonrpc = "2.0",
            id = 9,
            method = "cursor/task",
            params = %s,
        })
    ]],
        params_literal
    ))

    child.lua([[ vim.cmd("redraw") ]])
    child.api.nvim_eval("1")
end

describe("Cursor task flow", function()
    before_each(function()
        setup_child()
    end)

    after_each(function()
        child.stop()
    end)

    it("keeps prompt and final message as separate body sections", function()
        open_widget_and_wait()

        submit_prompt("Use a subagent")
        vim.uv.sleep(50)
        child.lua([[ vim.cmd("redraw") ]])
        child.api.nvim_eval("1")

        child.lua(string.format(
            [[
                local transport = require("tests.mocks.acp_transport_full_mock").instance
                transport:inject_notification(%q, {
                    sessionUpdate = "tool_call",
                    toolCallId = "tool-task-001",
                    kind = "other",
                    title = "Task: Subagent task",
                    status = "pending",
                    rawInput = {
                        _toolName = "task",
                        description = "Subagent returns SUBAGENT_OK",
                        prompt = "Reply with exactly SUBAGENT_OK",
                    },
                })
            ]],
            SESSION_ID
        ))
        child.lua([[ vim.cmd("redraw") ]])
        child.api.nvim_eval("1")

        child.lua(string.format(
            [[
                local transport = require("tests.mocks.acp_transport_full_mock").instance
                transport:inject_notification(%q, {
                    sessionUpdate = "tool_call_update",
                    toolCallId = "tool-task-001",
                    status = "completed",
                    rawOutput = {
                        finalMessage = "SUBAGENT_OK",
                        durationMs = 850,
                        isBackground = false,
                    },
                })
            ]],
            SESSION_ID
        ))
        child.lua([[ vim.cmd("redraw") ]])
        child.api.nvim_eval("1")

        inject_cursor_task([[
                {
                    toolCallId = "tool-task-001",
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
                }
            ]])
        vim.uv.sleep(50)
        child.lua([[ vim.cmd("redraw") ]])
        child.api.nvim_eval("1")

        local content = get_chat_content()
        assert.truthy(
            content:find(
                "SubAgent%(composer%-2%-fast: Subagent returns SUBAGENT_OK%)"
            ),
            "Task argument should carry model and description, got:\n"
                .. content
        )
        assert.truthy(
            content:find("Prompt:\nReply with exactly SUBAGENT_OK"),
            "Task prompt should be preserved, got:\n" .. content
        )
        assert.truthy(
            content:find("Final message:\nSUBAGENT_OK"),
            "Task final message should be shown with its header, got:\n"
                .. content
        )
        assert.is_falsy(
            content:find("Model: composer%-2%-fast"),
            "Task body should not repeat the model, got:\n" .. content
        )
        assert.is_falsy(
            content:find("\n---\n", 1, true),
            "Task body should not use the divider anymore, got:\n" .. content
        )

        complete_prompt()

        local restored_content = child.lua([[
                local tab_id = vim.api.nvim_get_current_tabpage()
                local session = require("agentic.session_registry").sessions[tab_id]
                local source = session.chat_history:get_replay_source()

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
            restored_content:find(
                "SubAgent%(composer%-2%-fast: Subagent returns SUBAGENT_OK%)"
            ),
            "Restored task should keep the enriched argument, got:\n"
                .. restored_content
        )
        assert.truthy(
            restored_content:find("Prompt:\nReply with exactly SUBAGENT_OK"),
            "Restored task should keep prompt, got:\n" .. restored_content
        )
        assert.truthy(
            restored_content:find("Final message:\nSUBAGENT_OK"),
            "Restored task should keep the final-message header, got:\n"
                .. restored_content
        )
        assert.is_falsy(
            restored_content:find("Model: composer%-2%-fast"),
            "Restored task should not repeat model in the body, got:\n"
                .. restored_content
        )
        assert.is_falsy(
            restored_content:find("\n---\n", 1, true),
            "Restored task should not use the divider anymore, got:\n"
                .. restored_content
        )
    end)
end)
