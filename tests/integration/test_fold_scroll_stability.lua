local assert = require("tests.helpers.assert")
local Config = require("agentic.config")

describe("Fold scroll stability", function()
    local ChatFolds = require("agentic.ui.chat_folds")
    local MessageWriter = require("agentic.ui.message_writer")

    --- @type agentic.UserConfig.Folding
    local original_folding
    --- @type agentic.UserConfig.AutoScroll
    local original_auto_scroll

    --- @type integer
    local bufnr
    --- @type integer
    local winid

    before_each(function()
        original_folding = Config.folding
        original_auto_scroll = Config.auto_scroll

        --- @diagnostic disable-next-line: assign-type-mismatch
        Config.folding = {
            tool_calls = {
                enabled = true,
                closed_by_default = true,
                min_lines = 5,
                kinds = {},
            },
        }
        --- @diagnostic disable-next-line: assign-type-mismatch
        Config.auto_scroll = { threshold = 10 }

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 20,
            row = 0,
            col = 0,
        })
    end)

    after_each(function()
        --- @diagnostic disable-next-line: assign-type-mismatch
        Config.folding = original_folding
        --- @diagnostic disable-next-line: assign-type-mismatch
        Config.auto_scroll = original_auto_scroll

        if vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- Fill buffer with filler lines and scroll to bottom
    --- @param line_count integer
    local function fill_and_scroll(line_count)
        local lines = {}
        for i = 1, line_count do
            table.insert(lines, "message line " .. i)
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

        -- Simulate auto-scroll: cursor at bottom, window scrolled down
        vim.api.nvim_win_call(winid, function()
            vim.cmd("normal! G0zb")
        end)
    end

    --- Get the last visible line in the window (1-indexed)
    --- @return integer last_visible_line
    local function get_last_visible_line()
        return vim.api.nvim_win_call(winid, function()
            return vim.fn.line("w$")
        end)
    end

    --- Generate body lines for a tool call
    --- @param count integer
    --- @return string[] body
    local function make_body(count)
        local body = {}
        for i = 1, count do
            table.insert(body, "output " .. i)
        end
        return body
    end

    it(
        "last buffer line stays visible after write_tool_call_block folds",
        function()
            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            writer:set_chat_folds(chat_folds)

            fill_and_scroll(50)

            -- Sanity: last line is visible before we write the block
            local total_before = vim.api.nvim_buf_line_count(bufnr)
            assert.equal(total_before, get_last_visible_line())

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc_1",
                kind = "execute",
                argument = "ls -la",
                status = "completed",
                body = make_body(25),
            }

            writer:write_tool_call_block(block)

            -- After write_tool_call_block returns (before vim.schedule fires),
            -- the last buffer line must still be visible in the window.
            -- If the fold caused a scroll jump, the last visible line will be
            -- much less than the total line count.
            local total_after = vim.api.nvim_buf_line_count(bufnr)
            local last_visible = get_last_visible_line()

            assert.equal(total_after, last_visible)
        end
    )

    it(
        "last buffer line stays visible after update_tool_call_block triggers fold",
        function()
            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            writer:set_chat_folds(chat_folds)

            fill_and_scroll(50)

            -- Write initial pending block (no fold created for pending status)
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc_2",
                kind = "execute",
                argument = "ls -la",
                status = "pending",
                body = make_body(25),
            }

            writer:write_tool_call_block(block)

            -- Re-scroll to bottom (write_tool_call_block added lines)
            vim.api.nvim_win_call(winid, function()
                vim.cmd("normal! G0zb")
            end)

            -- Update to completed — this triggers fold creation
            --- @type agentic.ui.MessageWriter.ToolCallBase
            local update = {
                tool_call_id = "tc_2",
                status = "completed",
            }

            writer:update_tool_call_block(update)

            -- The last buffer line must still be visible
            local total = vim.api.nvim_buf_line_count(bufnr)
            local last_visible = get_last_visible_line()

            assert.equal(total, last_visible)
        end
    )
end)
