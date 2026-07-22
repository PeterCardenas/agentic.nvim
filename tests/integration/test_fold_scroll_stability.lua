--- @diagnostic disable-next-line: unresolved-require
local assert = require("tests.helpers.assert")
--- @diagnostic disable-next-line: unresolved-require
local Config = require("agentic.config")
--- @diagnostic disable-next-line: unresolved-require
local BufHelpers = require("agentic.utils.buf_helpers")

describe("Fold scroll stability", function()
    --- @diagnostic disable-next-line: unresolved-require
    local ChatFolds = require("agentic.ui.chat_folds")
    --- @diagnostic disable-next-line: unresolved-require
    local MessageWriter = require("agentic.ui.message_writer")
    --- @diagnostic disable-next-line: unresolved-require
    local StatusAnimation = require("agentic.ui.status_animation")

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
                preview = false,
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
        BufHelpers.scroll_window_to_bottom(winid)
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
                vim.cmd("normal! G$zb")
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

    it(
        "active spinner tail stays visible after write_tool_call_block folds",
        function()
            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            local animation = StatusAnimation:new(bufnr)
            writer:set_chat_folds(chat_folds)

            fill_and_scroll(50)
            animation:start("generating")

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc_3",
                kind = "execute",
                argument = "ls -la",
                status = "completed",
                body = make_body(25),
            }

            writer:write_tool_call_block(block)
            animation:_render_frame()

            assert.is_true(BufHelpers.is_window_bottom_visible(winid))
            animation:stop()
        end
    )

    it(
        "active spinner tail stays visible after update_tool_call_block folds",
        function()
            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            local animation = StatusAnimation:new(bufnr)
            writer:set_chat_folds(chat_folds)

            fill_and_scroll(50)

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "tc_4",
                kind = "execute",
                argument = "ls -la",
                status = "pending",
                body = make_body(25),
            }

            writer:write_tool_call_block(block)
            BufHelpers.scroll_window_to_bottom(winid)
            animation:start("generating")

            --- @type agentic.ui.MessageWriter.ToolCallBase
            local update = {
                tool_call_id = "tc_4",
                status = "completed",
            }

            writer:update_tool_call_block(update)
            animation:_render_frame()

            assert.is_true(BufHelpers.is_window_bottom_visible(winid))
            animation:stop()
        end
    )

    it("does not stack stale folds across successive updates", function()
        -- Mirror the common real-world config where the preview inner fold is on.
        --- @diagnostic disable-next-line: inject-field
        Config.folding.tool_calls.preview = true
        --- @diagnostic disable-next-line: inject-field
        Config.folding.tool_calls.closed_by_default = false

        local tab = vim.api.nvim_get_current_tabpage()
        local chat_folds = ChatFolds:new(bufnr, tab)
        local writer = MessageWriter:new(bufnr)
        writer:set_chat_folds(chat_folds)

        --- @type agentic.ui.MessageWriter.ToolCallBlock
        local block = {
            tool_call_id = "tc_stack",
            kind = "execute",
            argument = "stream",
            status = "completed",
            body = make_body(10),
        }

        writer:write_tool_call_block(block)

        -- Two more updates with different bodies — merge path will grow the block
        writer:update_tool_call_block({
            tool_call_id = "tc_stack",
            status = "completed",
            body = (function()
                local b = {}
                for i = 1, 10 do
                    b[i] = "second " .. i
                end
                return b
            end)(),
        })

        writer:update_tool_call_block({
            tool_call_id = "tc_stack",
            status = "completed",
            body = (function()
                local b = {}
                for i = 1, 10 do
                    b[i] = "third " .. i
                end
                return b
            end)(),
        })

        local max_level = 0
        vim.api.nvim_win_call(winid, function()
            for i = 1, vim.api.nvim_buf_line_count(bufnr) do
                local lvl = vim.fn.foldlevel(i)
                if lvl > max_level then
                    max_level = lvl
                end
            end
        end)

        assert.equal(2, max_level)
    end)

    it(
        "keeps a single fold tree across claude-style statusless updates",
        function()
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.preview = true
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.closed_by_default = false

            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            writer:set_chat_folds(chat_folds)

            writer:write_tool_call_block({
                tool_call_id = "tc_claude_statusless",
                kind = "execute",
                argument = "multi-step command",
                status = "completed",
                body = make_body(10),
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_claude_statusless",
                body = {
                    "stdout chunk 1",
                    "stdout chunk 2",
                    "stdout chunk 3",
                    "stdout chunk 4",
                    "stdout chunk 5",
                    "stdout chunk 6",
                },
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_claude_statusless",
                body = {
                    "stderr chunk 1",
                    "stderr chunk 2",
                    "stderr chunk 3",
                    "stderr chunk 4",
                    "stderr chunk 5",
                    "stderr chunk 6",
                },
            })

            local outer_state = ChatFolds._get_fold_state(winid, 2)
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            local max_level = 0
            local outer_fold_count = 0

            vim.api.nvim_win_call(winid, function()
                local previous_level = 0
                for line = 1, vim.api.nvim_buf_line_count(bufnr) do
                    local level = vim.fn.foldlevel(line)
                    if level > max_level then
                        max_level = level
                    end
                    if level > 0 and previous_level == 0 then
                        outer_fold_count = outer_fold_count + 1
                    end
                    previous_level = level
                end
            end)

            assert.is_false(outer_state)
            assert.is_true(inner_state)
            assert.equal(2, max_level)
            assert.equal(1, outer_fold_count)
        end
    )

    it(
        "keeps later tool call folds stable when an earlier block updates again",
        function()
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.preview = true
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.closed_by_default = false

            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            writer:set_chat_folds(chat_folds)

            writer:write_tool_call_block({
                tool_call_id = "tc_first",
                kind = "execute",
                argument = "first command",
                status = "completed",
                body = make_body(10),
            })

            writer:write_tool_call_block({
                tool_call_id = "tc_second",
                kind = "execute",
                argument = "second command",
                status = "completed",
                body = make_body(10),
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_first",
                body = {
                    "late output 1",
                    "late output 2",
                    "late output 3",
                    "late output 4",
                    "late output 5",
                    "late output 6",
                },
            })

            local outer_fold_starts = {}
            local max_level = 0

            vim.api.nvim_win_call(winid, function()
                local previous_level = 0
                for line = 1, vim.api.nvim_buf_line_count(bufnr) do
                    local level = vim.fn.foldlevel(line)
                    if level > max_level then
                        max_level = level
                    end
                    if level > 0 and previous_level == 0 then
                        table.insert(outer_fold_starts, line)
                    end
                    previous_level = level
                end
            end)

            assert.equal(2, #outer_fold_starts)
            assert.equal(2, max_level)

            local first_outer = assert.not_nil(outer_fold_starts[1])
            local second_outer = assert.not_nil(outer_fold_starts[2])
            assert.is_false(ChatFolds._get_fold_state(winid, first_outer))
            assert.is_true(ChatFolds._get_fold_state(winid, first_outer + 5))
            assert.is_false(ChatFolds._get_fold_state(winid, second_outer))
            assert.is_true(ChatFolds._get_fold_state(winid, second_outer + 5))
        end
    )

    it(
        "renders multiple claude-style updates in one block with at most two folds",
        function()
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.preview = true
            --- @diagnostic disable-next-line: inject-field
            Config.folding.tool_calls.closed_by_default = false

            local tab = vim.api.nvim_get_current_tabpage()
            local chat_folds = ChatFolds:new(bufnr, tab)
            local writer = MessageWriter:new(bufnr)
            writer:set_chat_folds(chat_folds)

            writer:write_tool_call_block({
                tool_call_id = "tc_claude_ui",
                kind = "execute",
                argument = "claude multi update",
                status = "pending",
                body = {
                    "preparing command",
                    "checking environment",
                    "warming cache",
                    "collecting files",
                    "waiting for output",
                    "still running",
                },
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_claude_ui",
                status = "in_progress",
                body = {
                    "stdout 1",
                    "stdout 2",
                    "stdout 3",
                    "stdout 4",
                    "stdout 5",
                    "stdout 6",
                },
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_claude_ui",
                status = "in_progress",
                body = {
                    "stderr 1",
                    "stderr 2",
                    "stderr 3",
                    "stderr 4",
                    "stderr 5",
                    "stderr 6",
                },
            })

            writer:update_tool_call_block({
                tool_call_id = "tc_claude_ui",
                status = "completed",
                body = {
                    "exit code: 0",
                    "done 1",
                    "done 2",
                    "done 3",
                    "done 4",
                    "done 5",
                },
            })

            local tracker =
                assert.not_nil(writer.tool_call_blocks["tc_claude_ui"])
            assert.is_nil(tracker.body)

            local body_start, body_end = ChatFolds._resolve_body_range(
                bufnr,
                writer.tool_call_blocks,
                "tc_claude_ui"
            )
            body_start = assert.not_nil(body_start)
            body_end = assert.not_nil(body_end)

            local body = vim.api.nvim_buf_get_lines(
                bufnr,
                body_start - 1,
                body_end,
                false
            )

            assert.is_true(vim.tbl_contains(body, "preparing command"))
            assert.is_true(vim.tbl_contains(body, "stdout 1"))
            assert.is_true(vim.tbl_contains(body, "stderr 1"))
            assert.is_true(vim.tbl_contains(body, "exit code: 0"))

            local separator_count = 0
            for _, line in ipairs(body) do
                if line == "---" then
                    separator_count = separator_count + 1
                end
            end
            assert.equal(3, separator_count)

            local outer_fold_starts = {}
            local max_level = 0

            vim.api.nvim_win_call(winid, function()
                local previous_level = 0
                for line = body_start, body_end do
                    local level = vim.fn.foldlevel(line)
                    if level > max_level then
                        max_level = level
                    end
                    if level > 0 and previous_level == 0 then
                        table.insert(outer_fold_starts, line)
                    end
                    previous_level = level
                end
            end)

            assert.equal(1, #outer_fold_starts)
            assert.equal(2, max_level)

            local outer_start = assert.not_nil(outer_fold_starts[1])
            assert.is_false(ChatFolds._get_fold_state(winid, outer_start))
            assert.is_true(ChatFolds._get_fold_state(winid, outer_start + 5))
        end
    )

    it("reapplies folds after the chat window is reopened", function()
        --- @diagnostic disable-next-line: inject-field
        Config.folding.tool_calls.preview = true
        --- @diagnostic disable-next-line: inject-field
        Config.folding.tool_calls.closed_by_default = false

        local tab = vim.api.nvim_get_current_tabpage()
        local chat_folds = ChatFolds:new(bufnr, tab)
        local writer = MessageWriter:new(bufnr)
        writer:set_chat_folds(chat_folds)

        for i = 1, 3 do
            writer:write_tool_call_block({
                tool_call_id = "tc_show_" .. i,
                kind = "execute",
                argument = "cmd " .. i,
                status = "completed",
                body = make_body(10),
            })
        end

        local function count_outer_folds(w)
            local count = 0
            vim.api.nvim_win_call(w, function()
                local prev = 0
                for line = 1, vim.api.nvim_buf_line_count(bufnr) do
                    local lvl = vim.fn.foldlevel(line)
                    if lvl > 0 and prev == 0 then
                        count = count + 1
                    end
                    prev = lvl
                end
            end)
            return count
        end

        assert.equal(3, count_outer_folds(winid))

        chat_folds:capture_visible_fold_states(writer.tool_call_blocks)

        -- Wipe folds in the current window to simulate the real-world case
        -- where closing the chat window loses per-window manual folds. The
        -- headless harness preserves folds across window close/open, so
        -- clearing them here is the only way to force the reapply code path.
        vim.api.nvim_win_call(winid, function()
            vim.cmd("silent! normal! zE")
        end)

        assert.equal(0, count_outer_folds(winid))

        chat_folds:on_buf_win_enter(winid, writer.tool_call_blocks)

        assert.equal(3, count_outer_folds(winid))
    end)
end)
