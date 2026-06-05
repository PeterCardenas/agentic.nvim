--- @diagnostic disable: need-check-nil, unnecessary-if
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")
local BufHelpers = require("agentic.utils.buf_helpers")
local Logger = require("agentic.utils.logger")

describe("agentic.ui.ChatWidget", function()
    --- @type agentic.ui.ChatWidget
    local ChatWidget

    ChatWidget = require("agentic.ui.chat_widget")

    --- Helper to populate a dynamic buffer with content
    --- @param widget agentic.ui.ChatWidget
    --- @param name agentic.ui.ChatWidget.PanelNames
    --- @param content string[]
    local function fill_buffer(widget, name, content)
        local bufnr = widget.buf_nrs[name]
        vim.bo[bufnr].modifiable = true
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, content)
    end

    --- @param bufnr number
    --- @param key string
    --- @return table
    local function get_keymap_in_buf(bufnr, key)
        return vim.api.nvim_buf_call(bufnr, function()
            return vim.fn.maparg(key, "n", false, true)
        end)
    end

    -- Tests that behave identically regardless of layout position
    for _, position in ipairs({ "right", "left", "bottom" }) do
        -- Bottom layout uses 2 to avoid touching the screen edge
        local padding = position == "bottom" and 2 or 1

        describe(string.format("(%s layout)", position), function()
            local tab_page_id
            --- @type agentic.ui.ChatWidget
            local widget
            local original_position
            local skip_widget_destroy

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = position
                skip_widget_destroy = false

                vim.cmd("tabnew")
                tab_page_id = vim.api.nvim_get_current_tabpage()

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    tab_page_id,
                    on_submit_spy --[[@as function]]
                )
            end)

            after_each(function()
                if widget and not skip_widget_destroy then
                    pcall(function()
                        widget:destroy()
                    end)
                end
                pcall(function()
                    vim.cmd("tabclose")
                end)

                skip_widget_destroy = false
                Config.windows.position = original_position
            end)

            it("creates widget with valid buffer IDs", function()
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.chat))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.input))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.code))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.files))
                assert.is_true(vim.api.nvim_buf_is_valid(widget.buf_nrs.todos))
            end)

            it(
                "show() creates chat and input windows only when buffers are empty",
                function()
                    assert.is_falsy(widget:is_open())

                    widget:show()

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.chat)
                    )
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.input)
                    )
                    assert.is_nil(widget.win_nrs.code)
                    assert.is_nil(widget.win_nrs.files)
                    assert.is_nil(widget.win_nrs.todos)
                end
            )

            it("hide() closes all windows and preserves buffers", function()
                widget:show()

                local chat_win = widget.win_nrs.chat
                local input_win = widget.win_nrs.input
                local chat_buf = widget.buf_nrs.chat
                local input_buf = widget.buf_nrs.input

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(chat_win))
                assert.is_false(vim.api.nvim_win_is_valid(input_win))
                assert.is_nil(widget.win_nrs.chat)
                assert.is_nil(widget.win_nrs.input)
                assert.is_falsy(widget:is_open())

                assert.equal(chat_buf, widget.buf_nrs.chat)
                assert.equal(input_buf, widget.buf_nrs.input)
                assert.is_true(vim.api.nvim_buf_is_valid(chat_buf))
                assert.is_true(vim.api.nvim_buf_is_valid(input_buf))
            end)

            it("show() is idempotent when called multiple times", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat

                widget:show()

                assert.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it("hide() is safe when called multiple times", function()
                widget:show()
                widget:hide()

                assert.has_no_errors(function()
                    widget:hide()
                end)
            end)

            it("hides after a primary window closes", function()
                widget:show()
                local original_input_winid = widget.win_nrs.input
                local hide_stub = spy.stub(widget, "hide")

                widget.win_nrs.input = 999999
                widget:_hide_if_primary_window_closed()

                assert.equal(1, hide_stub.call_count)

                widget.win_nrs.input = original_input_winid
                hide_stub:revert()
            end)

            it("skips hide once the tabpage is gone", function()
                widget:show()
                local hide_stub = spy.stub(widget, "hide")

                widget.win_nrs.input = 999999
                vim.cmd("tabclose")
                widget:_hide_if_primary_window_closed()

                assert.equal(0, hide_stub.call_count)

                hide_stub:revert()
                skip_widget_destroy = true
            end)

            it("show() after hide() creates new windows", function()
                widget:show()
                local first_chat_win = widget.win_nrs.chat
                widget:hide()

                widget:show()

                assert.are_not.equal(first_chat_win, widget.win_nrs.chat)
                assert.is_false(vim.api.nvim_win_is_valid(first_chat_win))
                assert.is_true(vim.api.nvim_win_is_valid(widget.win_nrs.chat))
            end)

            it(
                "G reveals spinner footer lines below the last chat line",
                function()
                    local ns = vim.api.nvim_create_namespace(
                        "agentic_test_chat_bottom_tail"
                    )
                    local scroll_spy =
                        spy.on(BufHelpers, "scroll_window_to_bottom")

                    fill_buffer(widget, "chat", {
                        "header 1",
                        "header 2",
                        "header 3",
                        "header 4",
                        "agent: " .. string.rep("x", 20),
                    })

                    widget:show({ focus_prompt = false })
                    local chat_win = assert.not_nil(widget.win_nrs.chat)
                    vim.api.nvim_win_set_height(chat_win, 5)
                    vim.api.nvim_set_current_win(chat_win)
                    vim.api.nvim_win_set_cursor(chat_win, { 1, 0 })

                    vim.api.nvim_buf_set_extmark(
                        widget.buf_nrs.chat,
                        ns,
                        4,
                        0,
                        {
                            virt_lines = {
                                { { "" } },
                                { { " spinner ", "Comment" } },
                                { { "" } },
                            },
                            virt_lines_above = false,
                        }
                    )

                    assert.is_false(
                        BufHelpers.is_window_bottom_visible(chat_win)
                    )

                    local bottom_map =
                        get_keymap_in_buf(widget.buf_nrs.chat, "G")
                    assert.equal("G", bottom_map.lhs)
                    widget:go_to_chat_bottom()
                    vim.cmd("redraw")
                    scroll_spy:revert()

                    local cursor = vim.api.nvim_win_get_cursor(chat_win)
                    local winline = vim.api.nvim_win_call(chat_win, function()
                        return vim.fn.winline()
                    end)

                    assert.spy(scroll_spy).was.called_with(chat_win)
                    assert.equal(
                        vim.api.nvim_buf_line_count(widget.buf_nrs.chat),
                        cursor[1]
                    )
                    assert.equal(vim.api.nvim_win_get_height(chat_win), winline)
                end
            )

            it("windows are created in correct tabpage", function()
                widget:show()

                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.chat)
                )
                assert.equal(
                    tab_page_id,
                    vim.api.nvim_win_get_tabpage(widget.win_nrs.input)
                )
            end)

            it("hide() stops insert mode", function()
                widget:show()
                vim.api.nvim_set_current_win(widget.win_nrs.input)
                vim.cmd("startinsert")

                widget:hide()

                assert.are_not.equal("i", vim.fn.mode())
            end)

            describe("dynamic window creation", function()
                local test_cases = {
                    {
                        name = "code",
                        content = { "local foo = 'bar'", "print(foo)" },
                    },
                    {
                        name = "files",
                        content = { "file1.lua", "file2.lua" },
                    },
                    {
                        name = "todos",
                        content = { "todo1", "todo2" },
                    },
                }

                for _, tc in ipairs(test_cases) do
                    it(
                        string.format(
                            "creates %s window when buffer has content",
                            tc.name
                        ),
                        function()
                            fill_buffer(widget, tc.name, tc.content)
                            widget:show()

                            assert.is_true(
                                vim.api.nvim_win_is_valid(
                                    widget.win_nrs[tc.name]
                                )
                            )
                            assert.equal(
                                tab_page_id,
                                vim.api.nvim_win_get_tabpage(
                                    widget.win_nrs[tc.name]
                                )
                            )
                        end
                    )
                end
            end)

            it("hide() closes all dynamic windows when they exist", function()
                for _, name in ipairs({ "files", "code", "todos" }) do
                    fill_buffer(widget, name, { "content" })
                end

                widget:show()

                local files_win = widget.win_nrs.files
                local code_win = widget.win_nrs.code
                local todos_win = widget.win_nrs.todos

                widget:hide()

                assert.is_false(vim.api.nvim_win_is_valid(files_win))
                assert.is_false(vim.api.nvim_win_is_valid(code_win))
                assert.is_false(vim.api.nvim_win_is_valid(todos_win))
                assert.is_nil(widget.win_nrs.files)
                assert.is_nil(widget.win_nrs.code)
                assert.is_nil(widget.win_nrs.todos)
            end)

            it("caps window height at max_height", function()
                local lines = {}
                for i = 1, 23 do
                    lines[i] = "line" .. i
                end
                fill_buffer(widget, "code", lines)

                widget:show()

                local height = vim.api.nvim_win_get_height(widget.win_nrs.code)
                assert.equal(15, height)
            end)

            it(
                string.format("dynamic window uses %d line(s) padding", padding),
                function()
                    fill_buffer(widget, "code", { "line1", "line2", "line3" })

                    widget:show()

                    local height =
                        vim.api.nvim_win_get_height(widget.win_nrs.code)
                    assert.equal(3 + padding, height)
                end
            )

            it("sizes dynamic windows using wrapped line height", function()
                fill_buffer(widget, "files", { string.rep("x", 200) })

                widget:show({ focus_prompt = false })

                --- @type integer
                local files_win = assert.not_nil(widget.win_nrs.files)
                local text_height = vim.api.nvim_win_text_height(files_win, {
                    start_row = 0,
                }).all
                local expected = math.min(
                    text_height + padding,
                    Config.windows.files.max_height
                )

                assert.is_true(text_height > 1)
                assert.equal(expected, vim.api.nvim_win_get_height(files_win))
            end)

            it("resizes window when content changes", function()
                fill_buffer(widget, "code", { "line1", "line2", "line3" })

                widget:show()
                assert.equal(
                    3 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    3,
                    3,
                    false,
                    { "line4", "line5", "line6", "line7" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    7 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            it("shrinks window when content is removed", function()
                fill_buffer(
                    widget,
                    "code",
                    { "line1", "line2", "line3", "line4", "line5" }
                )

                widget:show()
                assert.equal(
                    5 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )

                vim.api.nvim_buf_set_lines(
                    widget.buf_nrs.code,
                    0,
                    -1,
                    false,
                    { "line1", "line2" }
                )

                widget:show({ focus_prompt = false })

                assert.equal(
                    2 + padding,
                    vim.api.nvim_win_get_height(widget.win_nrs.code)
                )
            end)

            describe("show() re-renders dynamic windows", function()
                it("closes window when buffer becomes empty", function()
                    fill_buffer(widget, "code", { "line1" })

                    widget:show()
                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )

                    vim.api.nvim_buf_set_lines(
                        widget.buf_nrs.code,
                        0,
                        -1,
                        false,
                        {}
                    )

                    widget:show({ focus_prompt = false })

                    assert.is_nil(widget.win_nrs.code)
                end)

                it("creates window on show when content exists", function()
                    fill_buffer(widget, "code", { "line1" })

                    assert.has_no_errors(function()
                        widget:show({ focus_prompt = false })
                    end)

                    assert.is_true(
                        vim.api.nvim_win_is_valid(widget.win_nrs.code)
                    )
                end)
            end)
        end)
    end

    -- Right and left layouts behave identically, only split direction differs
    for _, side in ipairs({ "right", "left" }) do
        describe(string.format("(%s layout) specific", side), function()
            --- @type agentic.ui.ChatWidget
            local widget
            local original_position

            before_each(function()
                original_position = Config.windows.position
                Config.windows.position = side

                vim.cmd("tabnew")

                local on_submit_spy = spy.new(function() end)
                widget = ChatWidget:new(
                    vim.api.nvim_get_current_tabpage(),
                    on_submit_spy --[[@as function]]
                )
            end)

            after_each(function()
                if widget then
                    pcall(function()
                        widget:destroy()
                    end)
                end
                pcall(function()
                    vim.cmd("tabclose")
                end)

                Config.windows.position = original_position
            end)

            it("input splits below chat", function()
                widget:show()

                local chat_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.chat)
                local input_pos =
                    vim.api.nvim_win_get_position(widget.win_nrs.input)

                -- Input row should be greater than chat row (below)
                assert.is_true(input_pos[1] > chat_pos[1])
                -- Same column position
                assert.equal(chat_pos[2], input_pos[2])
            end)

            it("input starts at 3 lines when empty", function()
                widget:show()

                local input_height =
                    vim.api.nvim_win_get_height(widget.win_nrs.input)
                assert.equal(3, input_height)
            end)

            it("input resizes to wrapped content on text changes", function()
                widget:show()

                --- @type integer
                local input_win = assert.not_nil(widget.win_nrs.input)
                local width = vim.api.nvim_win_get_width(input_win)
                local long_line = string.rep("x", math.floor(width * 4))
                local max_input_height =
                    math.max(2, Config.windows.input.height --[[@as integer]])

                fill_buffer(widget, "input", { long_line })
                vim.api.nvim_exec_autocmds("TextChanged", {
                    buffer = widget.buf_nrs.input,
                    modeline = false,
                })

                local text_height = vim.api.nvim_win_text_height(input_win, {
                    start_row = 0,
                }).all
                local expected = math.min(text_height + 1, max_input_height)

                assert.is_true(expected > 2)
                assert.equal(expected, vim.api.nvim_win_get_height(input_win))

                fill_buffer(widget, "input", { "" })
                vim.api.nvim_exec_autocmds("TextChanged", {
                    buffer = widget.buf_nrs.input,
                    modeline = false,
                })

                assert.equal(3, vim.api.nvim_win_get_height(input_win))
            end)
        end)
    end

    describe("(bottom layout) specific", function()
        --- @type agentic.ui.ChatWidget
        local widget
        local original_position

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "bottom"

            vim.cmd("tabnew")

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )
        end)

        after_each(function()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)

            Config.windows.position = original_position
        end)

        it("input splits right of chat", function()
            widget:show()

            local chat_pos = vim.api.nvim_win_get_position(widget.win_nrs.chat)
            local input_pos =
                vim.api.nvim_win_get_position(widget.win_nrs.input)

            -- Same row (horizontal split)
            assert.equal(chat_pos[1], input_pos[1])
            -- Input column should be greater than chat column (to the right)
            assert.is_true(input_pos[2] > chat_pos[2])
        end)

        it(
            "input width is proportional to chat via stack_width_ratio",
            function()
                widget:show()

                local chat_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.chat)
                local input_width =
                    vim.api.nvim_win_get_width(widget.win_nrs.input)
                local ratio = Config.windows.stack_width_ratio

                local expected = math.floor((chat_width + input_width) * ratio)

                -- Allow +-1 rounding tolerance
                assert.is_true(math.abs(input_width - expected) <= 1)
            end
        )
    end)

    describe("rotate_layout", function()
        --- @type agentic.ui.ChatWidget
        local widget
        local original_position
        --- @type TestStub
        local show_stub
        --- @type TestStub
        local notify_stub
        --- @type agentic.ui.ChatWidget|nil
        local widget2
        --- @type TestStub|nil
        local show_stub2

        before_each(function()
            original_position = Config.windows.position
            Config.windows.position = "right"

            local on_submit_spy = spy.new(function() end)
            widget = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy --[[@as function]]
            )

            show_stub = spy.stub(widget, "show")
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            if show_stub2 then
                show_stub2:revert()
                show_stub2 = nil
            end
            if widget2 then
                pcall(function()
                    widget2:destroy()
                end)
                widget2 = nil
            end

            show_stub:revert()
            notify_stub:revert()

            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end

            Config.windows.position = original_position
        end)

        it("uses default layouts when none provided", function()
            widget:rotate_layout()

            assert.equal("bottom", widget.current_position)
        end)

        it("uses default layouts when empty array provided", function()
            widget:rotate_layout({})

            assert.equal("bottom", widget.current_position)
        end)

        it(
            "stays on same layout and warns when only one is provided",
            function()
                local current = widget.current_position

                widget:rotate_layout({ current })

                local after_rotate = widget.current_position
                assert.equal(current, after_rotate)
                assert.spy(notify_stub).was.called(1)
                local msg = notify_stub.calls[1][1]
                assert.is_true(msg:find("Only one layout") ~= nil)
            end
        )

        it("rotates through all layouts in order", function()
            local layouts = { "right", "bottom", "left" }

            widget:rotate_layout(layouts)
            assert.equal("bottom", widget.current_position)

            widget:rotate_layout(layouts)
            assert.equal("left", widget.current_position)

            widget:rotate_layout(layouts)
            assert.equal("right", widget.current_position)
        end)

        it("falls back to first layout when current is not in list", function()
            local layouts = { "right", "bottom", "left" }
            local filtered = {}
            for _, layout in ipairs(layouts) do
                if layout ~= widget.current_position then
                    table.insert(filtered, layout)
                end
            end

            widget:rotate_layout(filtered)

            assert.equal(filtered[1], widget.current_position)
        end)

        it("calls show with focus_prompt false", function()
            widget:rotate_layout()

            assert.spy(show_stub).was.called(1)
            local call_args = show_stub.calls[1]
            -- call_args[1] is self, call_args[2] is the opts table
            assert.equal(false, call_args[2].focus_prompt)
        end)

        it("does not mutate Config.windows.position", function()
            widget:rotate_layout()

            assert.equal("right", Config.windows.position)
            assert.equal("bottom", widget.current_position)
        end)

        it("two widgets rotate independently", function()
            local on_submit_spy2 = spy.new(function() end)
            widget2 = ChatWidget:new(
                vim.api.nvim_get_current_tabpage(),
                on_submit_spy2 --[[@as function]]
            )
            show_stub2 = spy.stub(widget2, "show")

            -- Both start at "right" (Config default)
            assert.equal("right", widget.current_position)
            assert.equal("right", widget2.current_position)

            -- Rotate widget 1
            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("right", widget2.current_position)

            -- Rotate widget 2
            widget2:rotate_layout({ "right", "bottom", "left" })
            assert.equal("bottom", widget.current_position)
            assert.equal("bottom", widget2.current_position)

            -- Rotate widget 1 again
            widget:rotate_layout({ "right", "bottom", "left" })
            assert.equal("left", widget.current_position)
            assert.equal("bottom", widget2.current_position)
        end)
    end)

    describe("prompt navigation", function()
        local MessageWriter
        local tab_page_id
        --- @type agentic.ui.ChatWidget
        local widget
        --- @type TestStub
        local notify_stub

        before_each(function()
            MessageWriter = require("agentic.ui.message_writer")
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget =
                ChatWidget:new(tab_page_id, on_submit_spy --[[@as function]])
            widget.message_writer = MessageWriter:new(widget.buf_nrs.chat)

            fill_buffer(widget, "chat", {
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
            })
            local ns = vim.api.nvim_create_namespace("agentic_prompt_positions")
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 1, 0, {})
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 4, 0, {})
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 7, 0, {})
            widget:show({ focus_prompt = false })
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("warns when next prompt wraps to the first one", function()
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 8, 0 })

            widget:navigate_next_prompt()

            local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(2, cursor[1])
            assert.equal(0, cursor[2])
            assert.spy(notify_stub).was.called(1)
            assert
                .spy(notify_stub).was
                .called_with("Wrapped to first prompt", vim.log.levels.WARN)
        end)

        it("warns when previous prompt wraps to the last one", function()
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 2, 0 })

            widget:navigate_prev_prompt()

            local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(8, cursor[1])
            assert.equal(0, cursor[2])
            assert.spy(notify_stub).was.called(1)
            assert
                .spy(notify_stub).was
                .called_with("Wrapped to last prompt", vim.log.levels.WARN)
        end)
    end)

    describe("agent chunk navigation", function()
        local MessageWriter
        local tab_page_id
        --- @type agentic.ui.ChatWidget
        local widget
        --- @type TestStub
        local notify_stub

        before_each(function()
            MessageWriter = require("agentic.ui.message_writer")
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget =
                ChatWidget:new(tab_page_id, on_submit_spy --[[@as function]])
            widget.message_writer = MessageWriter:new(widget.buf_nrs.chat)

            fill_buffer(widget, "chat", {
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
            })
            local ns = vim.api.nvim_create_namespace(
                "agentic_agent_message_chunk_positions"
            )
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 1, 0, {})
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 4, 0, {})
            vim.api.nvim_buf_set_extmark(widget.buf_nrs.chat, ns, 7, 0, {})
            widget:show({ focus_prompt = false })
            notify_stub = spy.stub(Logger, "notify")
        end)

        after_each(function()
            notify_stub:revert()
            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("cycles to next agent message chunk with wrapping", function()
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 3 })

            widget:navigate_last_agent_message_chunk()
            local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(2, cursor[1])
            assert.equal(0, cursor[2])

            widget:navigate_last_agent_message_chunk()
            cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(5, cursor[1])
            assert.equal(0, cursor[2])

            widget:navigate_last_agent_message_chunk()
            cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(8, cursor[1])
            assert.equal(0, cursor[2])

            widget:navigate_last_agent_message_chunk()
            cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(2, cursor[1])
            assert.equal(0, cursor[2])
        end)

        it("jumps to the previous agent message chunk", function()
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 5, 4 })

            widget:navigate_prev_agent_message_chunk()

            local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(2, cursor[1])
            assert.equal(0, cursor[2])
        end)

        it("wraps previous agent message chunk from first to last", function()
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 2, 0 })

            widget:navigate_prev_agent_message_chunk()

            local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
            assert.equal(8, cursor[1])
            assert.equal(0, cursor[2])
        end)

        it(
            "warns when next agent message chunk wraps to the first one",
            function()
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 8, 0 })

                widget:navigate_last_agent_message_chunk()

                local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
                assert.equal(2, cursor[1])
                assert.equal(0, cursor[2])
                assert.spy(notify_stub).was.called(1)
                assert
                    .spy(notify_stub).was
                    .called_with(
                        "Wrapped to first agent message chunk",
                        vim.log.levels.WARN
                    )
            end
        )

        it(
            "warns when previous agent message chunk wraps to the last one",
            function()
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 2, 0 })

                widget:navigate_prev_agent_message_chunk()

                local cursor = vim.api.nvim_win_get_cursor(widget.win_nrs.chat)
                assert.equal(8, cursor[1])
                assert.equal(0, cursor[2])
                assert.spy(notify_stub).was.called(1)
                assert
                    .spy(notify_stub).was
                    .called_with("Wrapped to last agent message chunk", vim.log.levels.WARN)
            end
        )
    end)

    describe("keymaps", function()
        local tab_page_id
        --- @type agentic.ui.ChatWidget
        local widget
        local original_switch_provider
        local original_maplocalleader

        before_each(function()
            original_maplocalleader = vim.g.maplocalleader
            vim.g.maplocalleader = "\\"

            original_switch_provider = Config.keymaps.widget.switch_provider
            Config.keymaps.widget.switch_provider = "<localLeader>s"

            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()

            local on_submit_spy = spy.new(function() end)
            widget =
                ChatWidget:new(tab_page_id, on_submit_spy --[[@as function]])
        end)

        after_each(function()
            Config.keymaps.widget.switch_provider = original_switch_provider
            vim.g.maplocalleader = original_maplocalleader

            if widget then
                pcall(function()
                    widget:destroy()
                end)
            end
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        it("does not install a buffer-local provider switch keymap", function()
            local provider_map =
                get_keymap_in_buf(widget.buf_nrs.chat, "<localLeader>s")

            assert.is_nil(provider_map.lhs)
        end)
    end)
end)
