--- @diagnostic disable: invisible, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.MessageWriter", function()
    --- @type agentic.ui.MessageWriter
    local MessageWriter
    --- @type number
    local bufnr
    --- @type number
    local winid
    --- @type agentic.ui.MessageWriter
    local writer

    --- @type agentic.UserConfig.AutoScroll|nil
    local original_auto_scroll
    --- @type agentic.UserConfig.Folding|nil
    local original_folding

    before_each(function()
        original_auto_scroll = Config.auto_scroll
        original_folding = Config.folding
        MessageWriter = require("agentic.ui.message_writer")

        bufnr = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {})

        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 80,
            height = 40,
            row = 0,
            col = 0,
        })

        writer = MessageWriter:new(bufnr)
    end)

    after_each(function()
        Config.auto_scroll = original_auto_scroll --- @diagnostic disable-line: assign-type-mismatch
        Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch
        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    --- @param line_count integer
    --- @param cursor_line integer
    local function setup_buffer(line_count, cursor_line)
        local lines = {}
        for i = 1, line_count do
            lines[i] = "line " .. i
        end
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_win_set_cursor(winid, { cursor_line, 0 })
    end

    --- @param text string
    --- @return agentic.acp.SessionUpdateMessage
    local function make_message_update(text)
        return {
            sessionUpdate = "agent_message_chunk",
            content = { type = "text", text = text },
        }
    end

    --- @param id string
    --- @param status agentic.acp.ToolCallStatus
    --- @param body? string[]
    --- @return agentic.ui.MessageWriter.ToolCallBlock
    local function make_tool_call_block(id, status, body)
        return {
            tool_call_id = id,
            status = status,
            kind = "execute",
            argument = "ls",
            body = body or { "output" },
        }
    end

    describe("_check_auto_scroll", function()
        it(
            "returns true when cursor is within threshold of buffer end",
            function()
                setup_buffer(20, 15)
                assert.is_true(writer:_check_auto_scroll(bufnr))
            end
        )

        it("returns false when cursor is far from buffer end", function()
            setup_buffer(50, 1)
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns false when threshold is disabled (zero or nil)", function()
            setup_buffer(1, 1)

            Config.auto_scroll = { threshold = 0 }
            assert.is_false(writer:_check_auto_scroll(bufnr))

            Config.auto_scroll = nil
            assert.is_false(writer:_check_auto_scroll(bufnr))
        end)

        it("returns true when window is not visible", function()
            local hidden_buf = vim.api.nvim_create_buf(false, true)
            local hidden_writer = MessageWriter:new(hidden_buf)
            assert.is_true(hidden_writer:_check_auto_scroll(hidden_buf))
            vim.api.nvim_buf_delete(hidden_buf, { force = true })
        end)

        it("uses win_findbuf to check cursor across tabpages", function()
            setup_buffer(50, 1)

            vim.cmd("tabnew")
            local tab2 = vim.api.nvim_get_current_tabpage()

            assert.is_false(writer:_check_auto_scroll(bufnr))

            vim.api.nvim_set_current_tabpage(tab2)
            vim.cmd("tabclose")
        end)
    end)

    describe("_auto_scroll", function()
        it("evaluates _check_auto_scroll eagerly on first call", function()
            local check_scroll_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)

            assert.equal(1, check_scroll_spy.call_count)
            check_scroll_spy:revert()
        end)

        it("coalesces multiple calls into a single scheduled scroll", function()
            setup_buffer(20, 20)

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._scroll_scheduled)

            local check_spy = spy.on(writer, "_check_auto_scroll")
            writer:_auto_scroll(bufnr)
            writer:_auto_scroll(bufnr)

            assert.equal(0, check_spy.call_count)
            check_spy:revert()
        end)

        it("defers scrolling while command line is active", function()
            local current_mode = "c"
            local get_mode_stub = spy.stub(vim.api, "nvim_get_mode")
            get_mode_stub:invokes(function()
                return { mode = current_mode }
            end)

            local win_gettype_stub = spy.stub(vim.fn, "win_gettype")
            win_gettype_stub:returns("")

            local create_autocmd_stub = spy.stub(vim.api, "nvim_create_autocmd")
            local schedule_spy = spy.on(vim, "schedule")
            local win_call_spy = spy.on(vim.api, "nvim_win_call")

            setup_buffer(50, 1)
            writer._should_auto_scroll = true

            writer:_auto_scroll(bufnr)

            assert.equal(1, create_autocmd_stub.call_count)
            local autocmd_call = assert.not_nil(create_autocmd_stub.calls[1])
            assert.equal("CmdlineLeave", autocmd_call[1])
            assert.is_true(autocmd_call[2].once)
            assert.equal(0, schedule_spy.call_count)
            assert.equal(0, win_call_spy.call_count)
            assert.is_true(writer._cmdline_leave_scroll_pending)

            win_call_spy:revert()
            schedule_spy:revert()
            create_autocmd_stub:revert()
            win_gettype_stub:revert()
            get_mode_stub:revert()
        end)

        it("flushes deferred scrolling after command line leaves", function()
            local current_mode = "c"
            local get_mode_stub = spy.stub(vim.api, "nvim_get_mode")
            get_mode_stub:invokes(function()
                return { mode = current_mode }
            end)

            local win_gettype_stub = spy.stub(vim.fn, "win_gettype")
            win_gettype_stub:returns("")

            --- @type fun()|nil
            local leave_callback
            local create_autocmd_stub = spy.stub(vim.api, "nvim_create_autocmd")
            create_autocmd_stub:invokes(function(_event, opts)
                leave_callback = opts.callback
                return 1
            end)

            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)

            setup_buffer(50, 1)
            writer._should_auto_scroll = true

            writer:_auto_scroll(bufnr)
            assert.is_true(writer._cmdline_leave_scroll_pending)

            current_mode = "n"
            local callback = assert.not_nil(leave_callback)
            callback()

            assert.is_false(writer._cmdline_leave_scroll_pending)
            assert.is_nil(writer._should_auto_scroll)
            assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

            schedule_stub:revert()
            create_autocmd_stub:revert()
            win_gettype_stub:revert()
            get_mode_stub:revert()
        end)
    end)

    describe("_should_auto_scroll sticky field", function()
        it(
            "remains true after buffer growth despite cursor exceeding threshold",
            function()
                setup_buffer(20, 20)
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)

                local lines = {}
                for i = 1, 30 do
                    lines[i] = "tool output " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, lines)

                local check_spy = spy.on(writer, "_check_auto_scroll")
                writer:_auto_scroll(bufnr)
                assert.is_true(writer._should_auto_scroll)
                assert.equal(0, check_spy.call_count)
                check_spy:revert()
            end
        )

        it(
            "scheduled callback resets field and moves cursor to last line",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 1)
                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.is_nil(writer._should_auto_scroll)
                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                schedule_stub:revert()
            end
        )

        it(
            "scheduled callback leaves wrapped lines alone when bottom is already visible",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                vim.api.nvim_win_set_width(winid, 20)
                vim.api.nvim_win_set_height(winid, 5)
                vim.wo[winid].wrap = true
                vim.wo[winid].smoothscroll = true

                local long = string.rep("0123456789", 8)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    "top",
                    long,
                })

                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                local cursor = vim.api.nvim_win_get_cursor(winid)
                local winline = vim.api.nvim_win_call(winid, function()
                    return vim.fn.winline()
                end)

                assert.equal(1, cursor[1])
                assert.equal(0, cursor[2])
                assert.is_true(winline < vim.api.nvim_win_get_height(winid))

                schedule_stub:revert()
            end
        )

        it(
            "scheduled callback scrolls when user is on a different tabpage",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(20, 20)

                local new_lines = {}
                for i = 1, 30 do
                    new_lines[i] = "streamed line " .. i
                end
                vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, new_lines)

                vim.cmd("tabnew")
                local tab2 = vim.api.nvim_get_current_tabpage()

                writer._should_auto_scroll = true
                writer:_auto_scroll(bufnr)

                assert.equal(50, vim.api.nvim_win_get_cursor(winid)[1])

                vim.api.nvim_set_current_tabpage(tab2)
                vim.cmd("tabclose")

                schedule_stub:revert()
            end
        )

        it(
            "after reset, re-evaluates and returns false when user scrolled up",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    fn()
                end)

                setup_buffer(50, 50)
                writer:_auto_scroll(bufnr)
                assert.is_nil(writer._should_auto_scroll)
                assert.is_false(writer._scroll_scheduled)

                schedule_stub:revert()

                schedule_stub = spy.stub(vim, "schedule")

                vim.api.nvim_win_set_cursor(winid, { 1, 0 })

                writer:_auto_scroll(bufnr)
                assert.is_false(writer._should_auto_scroll)

                schedule_stub:revert()
            end
        )
    end)

    describe("auto-scroll with public write methods", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it(
            "write_message captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local long_text = {}
                for i = 1, 50 do
                    long_text[i] = "message line " .. i
                end

                writer:write_message(
                    make_message_update(table.concat(long_text, "\n"))
                )

                assert.is_true(writer._should_auto_scroll)
            end
        )

        it(
            "write_tool_call_block captures scroll decision before buffer grows",
            function()
                setup_buffer(10, 10)

                local body = {}
                for i = 1, 15 do
                    body[i] = "file" .. i .. ".lua"
                end

                --- @type agentic.ui.MessageWriter.ToolCallBlock
                local block = {
                    tool_call_id = "test-1",
                    status = "pending",
                    kind = "execute",
                    argument = "ls -la",
                    body = body,
                }
                writer:write_tool_call_block(block)

                assert.is_true(writer._should_auto_scroll)
                assert.is_true(vim.api.nvim_buf_line_count(bufnr) > 20)
            end
        )

        it("write_message does not scroll when user has scrolled up", function()
            setup_buffer(50, 1)

            writer:write_message(
                make_message_update("new content\nmore content")
            )

            assert.is_false(writer._should_auto_scroll)
        end)
    end)

    describe("write_message_chunk wrapped auto-scroll", function()
        --- @type TestStub
        local schedule_stub
        local scheduled

        before_each(function()
            scheduled = {}
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                table.insert(scheduled, fn)
            end)

            vim.api.nvim_win_set_width(winid, 20)
            vim.api.nvim_win_set_height(winid, 5)
            vim.wo[winid].wrap = true
            vim.wo[winid].smoothscroll = true
            vim.wo[winid].linebreak = false
            vim.wo[winid].breakindent = false
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        local function flush_scheduled()
            local callbacks = scheduled
            scheduled = {}
            for _, callback in ipairs(callbacks) do
                callback()
            end
        end

        it(
            "does not reposition the cursor while the wrapped tail stays visible",
            function()
                local BufHelpers = require("agentic.utils.buf_helpers")

                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    "header 1",
                    "header 2",
                    "header 3",
                    "agent: ",
                })
                vim.api.nvim_win_call(winid, function()
                    vim.cmd("normal! G$")
                end)

                writer:enable_auto_scroll()
                writer:write_message_chunk(make_message_update("1234567890"))
                flush_scheduled()
                local cursor_after_first = vim.api.nvim_win_get_cursor(winid)

                writer:write_message_chunk(make_message_update("abcdefghij"))
                flush_scheduled()
                local cursor_after_second = vim.api.nvim_win_get_cursor(winid)

                assert.are.same(cursor_after_first, cursor_after_second)
                assert.is_true(BufHelpers.is_window_bottom_visible(winid))
            end
        )

        it(
            "keeps the cursor on the bottom row when the wrapped tail exceeds the window height",
            function()
                local BufHelpers = require("agentic.utils.buf_helpers")

                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    "header 1",
                    "header 2",
                    "header 3",
                    "header 4",
                    "agent: ",
                })
                vim.api.nvim_win_call(winid, function()
                    vim.cmd("normal! G$")
                end)

                writer:enable_auto_scroll()

                for _, chunk in ipairs({
                    "1234567890",
                    "abcdefghij",
                    "KLMNOPQRST",
                    "uvwxyzABCD",
                    "EFGHIJKLMN",
                    "opqrstuvwx",
                    "YZ01234567",
                    "abcdefghij",
                    "klmnopqrst",
                    "uvwxyzABCD",
                    "EFGHIJKLMN",
                }) do
                    writer:write_message_chunk(make_message_update(chunk))
                    flush_scheduled()
                end

                local winline = vim.api.nvim_win_call(winid, function()
                    return vim.fn.winline()
                end)
                local view = vim.api.nvim_win_call(winid, function()
                    return vim.fn.winsaveview()
                end)

                assert.is_true(BufHelpers.is_window_bottom_visible(winid))
                assert.equal(vim.api.nvim_win_get_height(winid), winline)
                assert.is_true(view.skipcol > 0)
            end
        )
    end)

    describe("on_content_changed callback", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        it("stores and fires callback via set_on_content_changed", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(1)
        end)

        it("clears callback when set to nil", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])
            writer:set_on_content_changed(nil)

            writer:_notify_content_changed()

            assert.spy(callback_spy).was.called(0)
        end)

        it(
            "fires callback for each write method that produces content",
            function()
                local block = make_tool_call_block("cb-setup", "pending")
                writer:write_tool_call_block(block)

                local callback_spy = spy.new(function() end)
                writer:set_on_content_changed(callback_spy --[[@as function]])

                writer:write_message(make_message_update("hello"))
                writer:write_message_chunk(make_message_update("chunk"))
                writer:write_tool_call_block(
                    make_tool_call_block("cb-1", "pending")
                )
                writer:update_tool_call_block({
                    tool_call_id = "cb-setup",
                    status = "completed",
                    body = { "done" },
                })

                assert.spy(callback_spy).was.called(4)
            end
        )

        it("does not fire callback when content is empty", function()
            local callback_spy = spy.new(function() end)
            writer:set_on_content_changed(callback_spy --[[@as function]])

            writer:write_message(make_message_update(""))
            writer:write_message_chunk(make_message_update(""))

            assert.spy(callback_spy).was.called(0)
        end)
    end)

    describe("agent message chunk navigation positions", function()
        it("records only the start of each streamed agent message", function()
            writer:write_message_chunk(make_message_update("hello"))
            writer:write_message_chunk(make_message_update(" world"))
            writer:write_message_chunk(make_message_update("\nworld"))

            assert.same({ 1 }, writer:get_agent_message_chunk_positions())
        end)

        it(
            "records full agent messages with the same boundary rules",
            function()
                writer:write_message({
                    sessionUpdate = "user_message_chunk",
                    content = { type = "text", text = "user prompt" },
                })
                writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = {
                        type = "text",
                        text = "agent reply\nmore reply",
                    },
                })

                local positions = writer:get_agent_message_chunk_positions()
                assert.equal(1, #positions)
                local position = assert.not_nil(positions[1])
                local line = vim.api.nvim_buf_get_lines(
                    bufnr,
                    position - 1,
                    position,
                    false
                )[1]

                assert.equal("agent reply", line)
            end
        )

        it("records a new position after a non-message update", function()
            writer:write_message_chunk(make_message_update("hello"))
            writer:write_message_chunk({
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = "thinking" },
            })
            writer:write_message_chunk(make_message_update("world"))

            assert.same({ 1, 4 }, writer:get_agent_message_chunk_positions())
        end)

        it(
            "does not create a new position for a full agent message continuation",
            function()
                writer:write_message_chunk(make_message_update("hello"))
                writer:write_message({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "\n### done" },
                })

                assert.same({ 1 }, writer:get_agent_message_chunk_positions())
            end
        )

        it("clears prompt and agent chunk navigation positions", function()
            writer:record_prompt_position()
            writer:write_message({
                sessionUpdate = "user_message_chunk",
                content = {
                    type = "text",
                    text = table.concat({
                        "## User",
                        "",
                        "hello",
                        "",
                        "### Agent",
                    }, "\n"),
                },
            })
            writer:write_message_chunk(make_message_update("answer"))

            assert.same({ 3 }, writer:get_prompt_positions())
            assert.same({ 7 }, writer:get_agent_message_chunk_positions())

            writer:clear_navigation_positions()

            assert.same({}, writer:get_prompt_positions())
            assert.same({}, writer:get_agent_message_chunk_positions())
        end)
    end)

    describe("block highlights", function()
        it(
            "uses a dedicated highlight group for non-diff tool call bodies",
            function()
                local Theme = require("agentic.theme")
                local diff_ns =
                    vim.api.nvim_create_namespace("agentic_diff_highlights")

                writer:write_tool_call_block({
                    tool_call_id = "tool-highlight",
                    status = "completed",
                    kind = "execute",
                    argument = "ls",
                    body = { "output line" },
                })

                local extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    diff_ns,
                    0,
                    -1,
                    { details = true }
                )

                assert.is_true(#extmarks > 0)
                local details = assert.not_nil(extmarks[1][4])
                assert.equal(Theme.HL_GROUPS.TOOL_CALL_TEXT, details.hl_group)
                assert.is_not.equal("Comment", details.hl_group)
            end
        )

        it(
            "uses highlight priorities above treesitter for markdown-neutral text",
            function()
                local Theme = require("agentic.theme")
                local diff_ns =
                    vim.api.nvim_create_namespace("agentic_diff_highlights")
                local thought_ns =
                    vim.api.nvim_create_namespace("agentic_thought_highlights")

                writer:write_message_chunk({
                    sessionUpdate = "agent_thought_chunk",
                    content = { type = "text", text = "# heading\n*italic*" },
                })

                writer:write_tool_call_block({
                    tool_call_id = "tool-highlight-priority",
                    status = "completed",
                    kind = "execute",
                    argument = "printf",
                    body = { "# heading", "*italic*" },
                })

                local thought_extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    thought_ns,
                    0,
                    -1,
                    { details = true }
                )
                local tool_extmarks = vim.api.nvim_buf_get_extmarks(
                    bufnr,
                    diff_ns,
                    0,
                    -1,
                    { details = true }
                )

                local thought_priority
                for _, mark in ipairs(thought_extmarks) do
                    local mark_details = mark[4]
                    if
                        mark_details
                        and mark_details.hl_group
                            == Theme.HL_GROUPS.THOUGHT_TEXT
                    then
                        thought_priority = mark_details.priority
                        break
                    end
                end

                local tool_priority
                for _, mark in ipairs(tool_extmarks) do
                    local mark_details = mark[4]
                    if
                        mark_details
                        and mark_details.hl_group
                            == Theme.HL_GROUPS.TOOL_CALL_TEXT
                    then
                        tool_priority = mark_details.priority
                        break
                    end
                end

                thought_priority = assert.not_nil(thought_priority)
                tool_priority = assert.not_nil(tool_priority)
                assert.is_true(thought_priority > 100)
                assert.is_true(tool_priority > 100)
            end
        )
    end)

    describe("write_message_chunk trailing newline deferral", function()
        --- @type TestStub
        local schedule_stub

        before_each(function()
            schedule_stub = spy.stub(vim, "schedule")
        end)

        after_each(function()
            schedule_stub:revert()
        end)

        --- Helper: get all buffer lines
        --- @return string[]
        local function get_lines()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        end

        it(
            "does not create trailing empty line for chunk ending with newline",
            function()
                writer:write_message_chunk(make_message_update("hello\n"))

                local lines = get_lines()
                assert.equal(1, #lines)
                assert.equal("hello", lines[1])
                assert.is_true(writer._pending_newline)
            end
        )

        it("flushes deferred newline at start of next chunk", function()
            writer:write_message_chunk(make_message_update("hello\n"))
            writer:write_message_chunk(make_message_update("world"))

            local lines = get_lines()
            assert.equal(2, #lines)
            assert.equal("hello", lines[1])
            assert.equal("world", lines[2])
            assert.is_nil(writer._pending_newline)
        end)

        it("handles consecutive chunks with trailing newlines", function()
            writer:write_message_chunk(make_message_update("line1\n"))
            writer:write_message_chunk(make_message_update("line2\n"))
            writer:write_message_chunk(make_message_update("line3"))

            local lines = get_lines()
            assert.equal(3, #lines)
            assert.equal("line1", lines[1])
            assert.equal("line2", lines[2])
            assert.equal("line3", lines[3])
        end)

        it("handles chunk that is only a newline", function()
            writer:write_message_chunk(make_message_update("hello"))
            writer:write_message_chunk(make_message_update("\n"))
            writer:write_message_chunk(make_message_update("world"))

            local lines = get_lines()
            assert.equal(2, #lines)
            assert.equal("hello", lines[1])
            assert.equal("world", lines[2])
        end)

        it("preserves intentional blank lines from double newline", function()
            writer:write_message_chunk(make_message_update("above\n"))
            writer:write_message_chunk(make_message_update("\n"))
            writer:write_message_chunk(make_message_update("below"))

            local lines = get_lines()
            assert.equal(3, #lines)
            assert.equal("above", lines[1])
            assert.equal("", lines[2])
            assert.equal("below", lines[3])
        end)

        it("clears pending newline on thought-to-message transition", function()
            writer:write_message_chunk({
                sessionUpdate = "agent_thought_chunk",
                content = {
                    type = "text",
                    text = "thinking chunk that ends with newline\n",
                },
            })
            assert.is_true(writer._pending_newline)

            writer:write_message_chunk(make_message_update("regular chunk"))
            assert.is_nil(writer._pending_newline)
        end)

        it("clears pending newline when write_message is called", function()
            writer:write_message_chunk(make_message_update("chunk\n"))
            assert.is_true(writer._pending_newline)

            writer:write_message(make_message_update("full message"))
            assert.is_nil(writer._pending_newline)
        end)

        it(
            "produces same final output as naive approach for markdown content",
            function()
                -- Simulate streaming a markdown code block
                writer:write_message_chunk(make_message_update("Code:\n"))
                writer:write_message_chunk(make_message_update("\n"))
                writer:write_message_chunk(make_message_update("```lua\n"))
                writer:write_message_chunk(make_message_update("local x = 1\n"))
                writer:write_message_chunk(make_message_update("```\n"))
                writer:write_message_chunk(make_message_update("\n"))
                writer:write_message_chunk(make_message_update("Done!"))

                local lines = get_lines()
                assert.equal(7, #lines)
                assert.equal("Code:", lines[1])
                assert.equal("", lines[2])
                assert.equal("```lua", lines[3])
                assert.equal("local x = 1", lines[4])
                assert.equal("```", lines[5])
                assert.equal("", lines[6])
                assert.equal("Done!", lines[7])
            end
        )
    end)

    describe("tool call body display truncation", function()
        it("wraps execute output in a console code fence", function()
            writer:write_tool_call_block({
                tool_call_id = "console-output",
                status = "completed",
                kind = "execute",
                argument = "printf 'hello\\n'",
                body = { "hello" },
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            assert.same({
                " execute(printf 'hello\\n') ",
                "````console",
                "hello",
                "````",
                "",
            }, vim.list_slice(lines, 1, 5))
        end)

        it("shows multiline execute arguments in the body", function()
            writer:write_tool_call_block({
                tool_call_id = "heredoc-exec",
                status = "completed",
                kind = "execute",
                argument = table.concat({
                    "python3 - <<'PY'",
                    "from pathlib import Path",
                    "Path('/tmp/example').write_text('value')",
                    "PY",
                }, "\n"),
                body = { "done" },
            })

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local header
            for _, line in ipairs(lines) do
                if line:match("^ execute%(") then
                    header = line
                    break
                end
            end

            header = assert.not_nil(header)
            assert.equal(" execute(python3 - <<'PY') ", header)
            assert.same({
                "python3 - <<'PY'",
                "from pathlib import Path",
                "Path('/tmp/example').write_text('value')",
                "PY",
                "",
                "````console",
                "done",
                "````",
            }, vim.list_slice(lines, 2, 9))
        end)

        it("truncates large execute bodies in the chat buffer", function()
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    closed_by_default = false,
                    preview = true,
                    min_lines = 20,
                    max_display_lines = 2,
                },
            } --- @diagnostic disable-line: assign-type-mismatch

            local body = { "line 1", "line 2", "line 3", "line 4" }
            writer:write_tool_call_block(
                make_tool_call_block("big-exec", "completed", body)
            )

            local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
            local found_footer = false
            for _, line in ipairs(lines) do
                if line:match("more lines omitted from display") then
                    found_footer = true
                end
            end
            assert.is_true(found_footer)
            assert.same({
                " execute(ls) ",
                "````console",
                "line 1",
                "line 2",
                "... (2 more lines omitted from display; full output kept in session history)",
                "````",
            }, vim.list_slice(lines, 1, 6))
        end)
    end)

    describe("tool call body JSON formatting", function()
        it("formats single-line JSON body when writing the block", function()
            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            local block =
                make_tool_call_block("json-1", "completed", { json_text })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-1"]
            tracker = assert.not_nil(tracker)
            local body = assert.not_nil(tracker.body)
            assert.is_true(#body > 1)
        end)

        it("formats a JSON body with one trailing blank line", function()
            local long_value = string.rep("v", 100)
            local json_text = '{"key":"' .. long_value .. '","x":42}'

            local block = make_tool_call_block(
                "json-blank",
                "completed",
                { json_text, "" }
            )
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-blank"]
            tracker = assert.not_nil(tracker)
            local body = assert.not_nil(tracker.body)
            assert.equal("{", body[1])
            assert.equal("", body[#body])
            assert.is_true(#body > 2)
        end)

        it(
            "leaves placeholder text untouched and formats only JSON segments on update",
            function()
                local placeholder = "I'm going to fetch this"
                local long_value = string.rep("v", 100)
                local json_text = '{"key":"' .. long_value .. '","x":42}'

                local block = make_tool_call_block(
                    "json-stream",
                    "in_progress",
                    { placeholder }
                )
                writer:write_tool_call_block(block)

                writer:update_tool_call_block({
                    tool_call_id = "json-stream",
                    status = "completed",
                    body = { json_text },
                })

                local tracker = writer.tool_call_blocks["json-stream"]
                tracker = assert.not_nil(tracker)
                local body = assert.not_nil(tracker.body)
                assert.equal(placeholder, body[1])

                local separator_idx
                for i, line in ipairs(body) do
                    if line == "---" then
                        separator_idx = i
                        break
                    end
                end

                separator_idx = assert.not_nil(separator_idx)
                assert.is_true(#body - separator_idx > 1)
            end
        )

        it("leaves malformed JSON unchanged", function()
            local malformed = "{" .. string.rep("not valid json ", 10) .. "}"

            local block =
                make_tool_call_block("json-bad", "completed", { malformed })
            writer:write_tool_call_block(block)

            local tracker = writer.tool_call_blocks["json-bad"]
            tracker = assert.not_nil(tracker)
            assert.same({ malformed }, tracker.body)
        end)
    end)

    describe("_prepare_block_lines", function()
        local FileSystem
        --- @type TestStub
        local read_stub
        --- @type TestStub
        local path_stub

        before_each(function()
            FileSystem = require("agentic.utils.file_system")
            read_stub = spy.stub(FileSystem, "read_from_buffer_or_disk")
            path_stub = spy.stub(FileSystem, "to_absolute_path")
            path_stub:invokes(function(path)
                return path
            end)
        end)

        after_each(function()
            read_stub:revert()
            path_stub:revert()
        end)

        it("creates highlight ranges for pure insertion hunks", function()
            read_stub:returns({ "line1", "line2", "line3" })

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local block = {
                tool_call_id = "test-hl",
                status = "pending",
                kind = "edit",
                argument = "/test.lua",
                diff = {
                    old = { "line1", "line2", "line3" },
                    new = { "line1", "inserted", "line2", "line3" },
                },
            }

            local lines, highlight_ranges = writer:_prepare_block_lines(block)

            local found_inserted = false
            for _, line in ipairs(lines) do
                if line == "inserted" then
                    found_inserted = true
                    break
                end
            end
            assert.is_true(found_inserted)

            local new_ranges = vim.tbl_filter(function(r)
                return r.type == "new"
            end, highlight_ranges)
            assert.is_true(#new_ranges > 0)
            assert.equal("inserted", new_ranges[1].new_line)
        end)
    end)
end)
