--- @diagnostic disable: unresolved-require
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

describe("gf navigation in widget buffers", function()
    local child = Child:new()

    --- Creates a real file on disk and returns its absolute path, so
    --- `_goto_file_under_cursor` can resolve and open it for real.
    --- @return string abs_path
    local function create_test_file()
        return child.lua([[
            local path = "/tmp/agentic-gf-test-" .. tostring(vim.uv.hrtime()) .. ".lua"
            vim.fn.writefile({ "line1", "line2", "line3" }, path)
            return path
        ]])
    end

    before_each(function()
        child.setup()

        -- Defines a two-split editor layout and deliberately identifies
        -- (and focuses) whichever split is NOT first in
        -- nvim_tabpage_list_wins() order -- `find_first_non_widget_window`
        -- always returns the first one, so only targeting the non-first
        -- split makes these tests actually discriminate "first window" from
        -- "focused/previously-focused window".
        child.lua([[
            function _G.gf_test_setup_two_splits()
                local suffix = tostring(vim.uv.hrtime())
                local function make_buffer(name, lines)
                    local bufnr = vim.api.nvim_create_buf(true, false)
                    vim.api.nvim_buf_set_name(bufnr, name)
                    vim.bo[bufnr].bufhidden = "hide"
                    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                    return bufnr
                end

                local buf_a = make_buffer(
                    "/tmp/agentic-gf-split-a-" .. suffix .. ".lua",
                    { "a-1", "a-2" }
                )
                vim.api.nvim_win_set_buf(0, buf_a)

                vim.cmd("vsplit")
                local buf_b = make_buffer(
                    "/tmp/agentic-gf-split-b-" .. suffix .. ".lua",
                    { "b-1", "b-2" }
                )
                vim.api.nvim_win_set_buf(0, buf_b)

                local tab_id = vim.api.nvim_get_current_tabpage()
                local wins = vim.api.nvim_tabpage_list_wins(tab_id)

                local win_for_buf = {}
                for _, winid in ipairs(wins) do
                    win_for_buf[vim.api.nvim_win_get_buf(winid)] = winid
                end

                local first_winid = wins[1]
                local target_bufnr = (win_for_buf[buf_a] ~= first_winid) and buf_a
                    or buf_b
                local other_bufnr = (target_bufnr == buf_a) and buf_b or buf_a
                local other_lines = (other_bufnr == buf_a) and { "a-1", "a-2" }
                    or { "b-1", "b-2" }

                local target_winid = win_for_buf[target_bufnr]
                local other_winid = win_for_buf[other_bufnr]

                -- Sanity check: the target really is NOT first in list order.
                assert(target_winid ~= first_winid)

                vim.api.nvim_set_current_win(target_winid)

                return {
                    tab_id = tab_id,
                    target_bufnr = target_bufnr,
                    target_winid = target_winid,
                    other_bufnr = other_bufnr,
                    other_winid = other_winid,
                    other_lines = other_lines,
                }
            end
        ]])
    end)

    after_each(function()
        child.stop()
    end)

    it(
        "opens the file in the previously-focused split when not maximized, leaving the other split and the chat window untouched",
        function()
            local file_path = create_test_file()
            local setup_info =
                child.lua([[ return _G.gf_test_setup_two_splits() ]])

            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Re-establish target_winid as the alternate window right
            -- before jumping to chat, matching "user was in split, jumped
            -- to chat, pressed gf".
            child.lua(string.format(
                [[
                local session = require("agentic.session_registry").sessions[%d]
                vim.api.nvim_set_current_win(%d)
                vim.api.nvim_set_current_win(session.widget.win_nrs.chat)
            ]],
                setup_info.tab_id,
                setup_info.target_winid
            ))

            local result = child.lua(
                string.format(
                    [[
                local tab_id = %d
                local session = require("agentic.session_registry").sessions[tab_id]
                local widget = session.widget
                local file_path = %q
                local other_bufnr = %d

                vim.bo[widget.buf_nrs.chat].modifiable = true
                vim.api.nvim_buf_set_lines(widget.buf_nrs.chat, 0, -1, false, { file_path })
                vim.bo[widget.buf_nrs.chat].modifiable = false
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })

                widget:_goto_file_under_cursor()

                local current_buf = vim.api.nvim_get_current_buf()
                local current_name = vim.api.nvim_buf_get_name(current_buf)

                local other_bufnr_visible = false
                local other_bufnr_lines = nil
                for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    if bufnr == other_bufnr then
                        other_bufnr_visible = true
                        other_bufnr_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                    end
                end

                local chat_winid = widget.win_nrs.chat
                local chat_win_valid = chat_winid ~= nil
                    and vim.api.nvim_win_is_valid(chat_winid)
                local chat_win_buf = chat_win_valid
                    and vim.api.nvim_win_get_buf(chat_winid)
                    or nil

                return {
                    current_name = current_name,
                    other_bufnr_visible = other_bufnr_visible,
                    other_bufnr_lines = other_bufnr_lines,
                    chat_win_valid = chat_win_valid,
                    chat_win_buf_is_chat_buf = chat_win_buf == widget.buf_nrs.chat,
                }
            ]],
                    setup_info.tab_id,
                    file_path,
                    setup_info.other_bufnr
                )
            )

            assert.equal(file_path, result.current_name)
            assert.is_true(result.other_bufnr_visible)
            assert.same(setup_info.other_lines, result.other_bufnr_lines)
            assert.is_true(result.chat_win_valid)
            assert.is_true(result.chat_win_buf_is_chat_buf)
        end
    )

    it(
        "minimizes first when maximized, then opens the file in the split that was focused before maximizing -- not the other split",
        function()
            local file_path = create_test_file()
            local setup_info =
                child.lua([[ return _G.gf_test_setup_two_splits() ]])

            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Re-establish target_winid as the alternate window right
            -- before maximizing, so `_capture_maximize_state`'s internal
            -- `_get_preferred_editor_focus_winid()` records it as the
            -- focused leaf to restore later.
            child.lua(string.format(
                [[
                local session = require("agentic.session_registry").sessions[%d]
                vim.api.nvim_set_current_win(%d)
                vim.api.nvim_set_current_win(session.widget.win_nrs.chat)
                session.widget:_toggle_full_width()
            ]],
                setup_info.tab_id,
                setup_info.target_winid
            ))
            child.flush()

            local result = child.lua(
                string.format(
                    [[
                local tab_id = %d
                local session = require("agentic.session_registry").sessions[tab_id]
                local widget = session.widget
                local file_path = %q
                local target_bufnr = %d
                local other_bufnr = %d

                vim.bo[widget.buf_nrs.chat].modifiable = true
                vim.api.nvim_buf_set_lines(widget.buf_nrs.chat, 0, -1, false, { file_path })
                vim.bo[widget.buf_nrs.chat].modifiable = false
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })

                local was_maximized = widget._maximize_state ~= nil

                widget:_goto_file_under_cursor()

                local current_buf = vim.api.nvim_get_current_buf()
                local current_name = vim.api.nvim_buf_get_name(current_buf)

                local other_bufnr_visible = false
                local other_bufnr_lines = nil
                local editor_window_count = 0
                local widget_bufs = {}
                for _, bufnr in pairs(widget.buf_nrs) do
                    widget_bufs[bufnr] = true
                end
                local agentic_fts = {
                    AgenticChat = true,
                    AgenticInput = true,
                    AgenticTodos = true,
                    AgenticCode = true,
                    AgenticFiles = true,
                    AgenticDiagnostics = true,
                }

                for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    if bufnr == other_bufnr then
                        other_bufnr_visible = true
                        other_bufnr_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
                    end
                    local ft = vim.bo[bufnr].filetype
                    if not widget_bufs[bufnr] and not agentic_fts[ft] then
                        editor_window_count = editor_window_count + 1
                    end
                end

                return {
                    was_maximized = was_maximized,
                    is_maximized_after = widget._maximize_state ~= nil,
                    current_name = current_name,
                    current_buf_is_target_bufnr = current_buf == target_bufnr,
                    other_bufnr_visible = other_bufnr_visible,
                    other_bufnr_lines = other_bufnr_lines,
                    editor_window_count = editor_window_count,
                }
            ]],
                    setup_info.tab_id,
                    file_path,
                    setup_info.target_bufnr,
                    setup_info.other_bufnr
                )
            )

            assert.is_true(result.was_maximized)
            assert.is_false(result.is_maximized_after)
            -- The file replaced the TARGET split's buffer (the one that was
            -- focused before maximizing), not the other split.
            assert.equal(file_path, result.current_name)
            assert.is_false(result.current_buf_is_target_bufnr)
            -- The other split survived the restore completely untouched.
            assert.is_true(result.other_bufnr_visible)
            assert.same(setup_info.other_lines, result.other_bufnr_lines)
            -- Layout genuinely restored: still exactly 2 editor windows (the
            -- untouched other split + the one now showing the gf target).
            assert.equal(2, result.editor_window_count)
        end
    )

    it(
        "does not clobber an excluded-filetype window (e.g. a file explorer) that happens to be the alternate window",
        function()
            local file_path = create_test_file()

            local setup = child.lua([[
                local suffix = tostring(vim.uv.hrtime())
                local editor_buf = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(
                    editor_buf,
                    "/tmp/agentic-gf-excluded-editor-" .. suffix .. ".lua"
                )
                vim.api.nvim_buf_set_lines(
                    editor_buf,
                    0,
                    -1,
                    false,
                    { "editor-1", "editor-2" }
                )
                vim.api.nvim_win_set_buf(0, editor_buf)

                vim.cmd("vsplit")
                local explorer_buf = vim.api.nvim_create_buf(false, true)
                vim.bo[explorer_buf].filetype = "neo-tree"
                vim.api.nvim_buf_set_lines(
                    explorer_buf,
                    0,
                    -1,
                    false,
                    { "fake-tree-content" }
                )
                vim.api.nvim_win_set_buf(0, explorer_buf)
                local explorer_winid = vim.api.nvim_get_current_win()

                return {
                    tab_id = vim.api.nvim_get_current_tabpage(),
                    explorer_buf = explorer_buf,
                    explorer_winid = explorer_winid,
                }
            ]])

            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Focus the explorer window right before jumping to chat, so it
            -- becomes winnr('#') -- exactly the scenario that clobbered
            -- nvim-tree in the real reproduction.
            child.lua(string.format(
                [[
                local session = require("agentic.session_registry").sessions[%d]
                vim.api.nvim_set_current_win(%d)
                vim.api.nvim_set_current_win(session.widget.win_nrs.chat)
            ]],
                setup.tab_id,
                setup.explorer_winid
            ))

            local result = child.lua(string.format(
                [[
                local tab_id = %d
                local session = require("agentic.session_registry").sessions[tab_id]
                local widget = session.widget
                local file_path = %q
                local explorer_buf = %d

                vim.bo[widget.buf_nrs.chat].modifiable = true
                vim.api.nvim_buf_set_lines(widget.buf_nrs.chat, 0, -1, false, { file_path })
                vim.bo[widget.buf_nrs.chat].modifiable = false
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })

                widget:_goto_file_under_cursor()

                local current_buf = vim.api.nvim_get_current_buf()
                local current_name = vim.api.nvim_buf_get_name(current_buf)

                local explorer_win_untouched = false
                for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                    if vim.api.nvim_win_get_buf(winid) == explorer_buf then
                        explorer_win_untouched = true
                    end
                end

                return {
                    current_name = current_name,
                    explorer_win_untouched = explorer_win_untouched,
                    explorer_buf_valid = vim.api.nvim_buf_is_valid(explorer_buf),
                }
            ]],
                setup.tab_id,
                file_path,
                setup.explorer_buf
            ))

            assert.equal(file_path, result.current_name)
            assert.is_true(result.explorer_win_untouched)
            assert.is_true(result.explorer_buf_valid)
        end
    )

    it(
        "does not clobber a real terminal window that happens to be the alternate window",
        function()
            local file_path = create_test_file()

            local setup = child.lua([[
                local suffix = tostring(vim.uv.hrtime())
                local editor_buf = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(
                    editor_buf,
                    "/tmp/agentic-gf-terminal-editor-" .. suffix .. ".lua"
                )
                vim.api.nvim_buf_set_lines(
                    editor_buf,
                    0,
                    -1,
                    false,
                    { "editor-1", "editor-2" }
                )
                vim.api.nvim_win_set_buf(0, editor_buf)

                vim.cmd("vsplit")
                -- A real terminal buffer has buftype == "terminal" but an
                -- EMPTY filetype -- exactly the gap that let terminals slip
                -- past EXCLUDED_FILETYPES["terminal"] (which keys on
                -- filetype and therefore never matched).
                vim.cmd("terminal sh -c 'sleep 30'")
                vim.cmd("sleep 200m")
                local terminal_buf = vim.api.nvim_get_current_buf()
                local terminal_job_id = vim.b[terminal_buf].terminal_job_id
                local terminal_winid = vim.api.nvim_get_current_win()

                return {
                    tab_id = vim.api.nvim_get_current_tabpage(),
                    terminal_buf = terminal_buf,
                    terminal_job_id = terminal_job_id,
                    terminal_winid = terminal_winid,
                }
            ]])

            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            child.lua(string.format(
                [[
                local session = require("agentic.session_registry").sessions[%d]
                vim.api.nvim_set_current_win(%d)
                vim.api.nvim_set_current_win(session.widget.win_nrs.chat)
            ]],
                setup.tab_id,
                setup.terminal_winid
            ))

            local result = child.lua(string.format(
                [[
                local tab_id = %d
                local session = require("agentic.session_registry").sessions[tab_id]
                local widget = session.widget
                local file_path = %q
                local terminal_buf = %d

                vim.bo[widget.buf_nrs.chat].modifiable = true
                vim.api.nvim_buf_set_lines(widget.buf_nrs.chat, 0, -1, false, { file_path })
                vim.bo[widget.buf_nrs.chat].modifiable = false
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })

                widget:_goto_file_under_cursor()

                local current_buf = vim.api.nvim_get_current_buf()
                local current_name = vim.api.nvim_buf_get_name(current_buf)

                local terminal_win_untouched = false
                for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                    if vim.api.nvim_win_get_buf(winid) == terminal_buf then
                        terminal_win_untouched = true
                    end
                end

                return {
                    current_name = current_name,
                    terminal_win_untouched = terminal_win_untouched,
                    terminal_buf_valid = vim.api.nvim_buf_is_valid(terminal_buf),
                }
            ]],
                setup.tab_id,
                file_path,
                setup.terminal_buf
            ))

            -- Hygiene: stop the shell job we spawned for this test.
            child.lua(
                string.format(
                    [[ pcall(vim.fn.jobstop, %d) ]],
                    setup.terminal_job_id
                )
            )

            assert.equal(file_path, result.current_name)
            assert.is_true(result.terminal_win_untouched)
            assert.is_true(result.terminal_buf_valid)
        end
    )
end)
