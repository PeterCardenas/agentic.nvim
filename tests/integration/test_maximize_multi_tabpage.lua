--- @diagnostic disable: redundant-parameter, unnecessary-if, unresolved-require
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Agentic widget filetypes that should NEVER appear as editor windows
local AGENTIC_FILETYPES = {
    AgenticChat = true,
    AgenticInput = true,
    AgenticTodos = true,
    AgenticCode = true,
    AgenticFiles = true,
    AgenticDiagnostics = true,
}

describe("Maximize toggle with multiple tabpages", function()
    local child = Child:new()

    --- @param tabpage number
    --- @return string[]
    local function get_tabpage_filetypes(tabpage)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        local filetypes = {}
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            table.insert(filetypes, ft)
        end
        table.sort(filetypes)
        return filetypes
    end

    --- @param tabpage number
    --- @return table|nil
    local function snapshot_editor_layout(tabpage)
        return child.lua(string.format(
            [[
            local tab_id = %d
            local session = require("agentic.session_registry").sessions[tab_id]
            local widget_bufs = {}
            if session and session.widget then
                for _, bufnr in pairs(session.widget.buf_nrs) do
                    widget_bufs[bufnr] = true
                end
            end

            local agentic_fts = {
                AgenticChat = true,
                AgenticInput = true,
                AgenticTodos = true,
                AgenticCode = true,
                AgenticFiles = true,
                AgenticDiagnostics = true,
            }

            local function convert(node)
                local kind = node[1]
                if kind == "leaf" then
                    local winid = node[2]
                    local bufnr = vim.api.nvim_win_get_buf(winid)
                    local filetype = vim.bo[bufnr].filetype
                    if widget_bufs[bufnr] or agentic_fts[filetype] then
                        return nil
                    end

                    return {
                        kind = "leaf",
                        bufnr = bufnr,
                        name = vim.api.nvim_buf_get_name(bufnr),
                        filetype = filetype,
                    }
                end

                local children = {}
                for _, child in ipairs(node[2]) do
                    local converted = convert(child)
                    if converted then
                        table.insert(children, converted)
                    end
                end

                if #children == 0 then
                    return nil
                end

                if #children == 1 then
                    return children[1]
                end

                return {
                    kind = kind,
                    children = children,
                }
            end

            local tabnr = vim.api.nvim_tabpage_get_number(tab_id)
            return convert(vim.fn.winlayout(tabnr))
        ]],
            tabpage
        ))
    end

    --- @param tabpage number
    --- @return integer
    local function count_editor_windows(tabpage)
        return child.lua(string.format(
            [[
            local tab_id = %d
            local session = require("agentic.session_registry").sessions[tab_id]
            local widget_bufs = {}
            if session and session.widget then
                for _, bufnr in pairs(session.widget.buf_nrs) do
                    widget_bufs[bufnr] = true
                end
            end

            local count = 0
            for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                local bufnr = vim.api.nvim_win_get_buf(winid)
                local filetype = vim.bo[bufnr].filetype
                if not widget_bufs[bufnr] and not (%s)[filetype] then
                    count = count + 1
                end
            end
            return count
        ]],
            tabpage,
            [[{
                AgenticChat = true,
                AgenticInput = true,
                AgenticTodos = true,
                AgenticCode = true,
                AgenticFiles = true,
                AgenticDiagnostics = true,
            }]]
        ))
    end

    --- @param tabpage number
    --- @param msg string|nil
    local function assert_no_agentic_in_editor_windows(tabpage, msg)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            if AGENTIC_FILETYPES[ft] then
                error(
                    string.format(
                        "%s: found Agentic filetype '%s' in window %d (buf %d) on tabpage %s",
                        msg or "Agentic buffer leaked into editor window",
                        ft,
                        winid,
                        bufnr,
                        tostring(tabpage)
                    )
                )
            end
        end
    end

    --- @param tabpage number
    --- @return table
    local function snapshot_tab_state(tabpage)
        return child.lua(string.format(
            [[
            local tab_id = %d
            local session = require("agentic.session_registry").sessions[tab_id]
            return {
                winlayout = vim.fn.winlayout(vim.api.nvim_tabpage_get_number(tab_id)),
                is_maximized = session ~= nil
                    and session.widget._maximize_state ~= nil
                    or false,
            }
        ]],
            tabpage
        ))
    end

    local function toggle_widget()
        child.lua([[ require("agentic").toggle() ]])
        child.flush()
    end

    --- @param tabpage number
    local function toggle_maximize(tabpage)
        child.lua(string.format(
            [[
            local session = require("agentic.session_registry").sessions[%d]
            session.widget:_toggle_full_width()
        ]],
            tabpage
        ))
        child.flush()
    end

    --- @param tabpage number
    local function switch_to_tab(tabpage)
        child.lua(
            string.format([[ vim.api.nvim_set_current_tabpage(%d) ]], tabpage)
        )
        child.flush()
    end

    --- @return { left: integer, top: integer, bottom: integer }
    local function create_mixed_editor_layout()
        return child.lua([[
            local suffix = tostring(vim.uv.hrtime())
            local function make_buffer(name, lines, bufhidden)
                local bufnr = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(bufnr, name)
                vim.bo[bufnr].bufhidden = bufhidden or "hide"
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
                return bufnr
            end

            local left = make_buffer("/tmp/agentic-max-left-" .. suffix .. ".lua", {
                "left-1",
                "left-2",
            })
            vim.api.nvim_win_set_buf(0, left)
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            vim.cmd("vsplit")
            local top = make_buffer("/tmp/agentic-max-top-" .. suffix .. ".lua", {
                "top-1",
                "top-2",
                "top-3",
            })
            vim.api.nvim_win_set_buf(0, top)
            vim.api.nvim_win_set_cursor(0, { 3, 0 })

            vim.cmd("split")
            local bottom = make_buffer("/tmp/agentic-max-bottom-" .. suffix .. ".lua", {
                "bottom-1",
                "bottom-2",
                "bottom-3",
                "bottom-4",
            })
            vim.api.nvim_win_set_buf(0, bottom)
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            return {
                left = left,
                top = top,
                bottom = bottom,
            }
        ]])
    end

    --- @return { wipe: integer, delete: integer }
    local function create_bufhidden_editor_layout()
        return child.lua([[
            local function make_buffer(name, bufhidden)
                local bufnr = vim.api.nvim_create_buf(true, false)
                vim.api.nvim_buf_set_name(bufnr, name)
                vim.bo[bufnr].bufhidden = bufhidden
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                    name,
                    "content",
                })
                return bufnr
            end

            local wipe_buf = make_buffer("/tmp/agentic-wipe.lua", "wipe")
            vim.api.nvim_win_set_buf(0, wipe_buf)

            vim.cmd("vsplit")
            local delete_buf = make_buffer("/tmp/agentic-delete.lua", "delete")
            vim.api.nvim_win_set_buf(0, delete_buf)
            vim.api.nvim_win_set_cursor(0, { 2, 0 })

            return {
                wipe = wipe_buf,
                delete = delete_buf,
            }
        ]])
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it("off-tab direct maximize and unmaximize calls are no-ops", function()
        create_mixed_editor_layout()
        toggle_widget()

        local tab1_id = child.api.nvim_get_current_tabpage()
        local before = snapshot_tab_state(tab1_id)

        child.cmd("tabnew")
        local tab2_id = child.api.nvim_get_current_tabpage()

        toggle_maximize(tab1_id)

        local after_off_tab_maximize = snapshot_tab_state(tab1_id)
        assert.same(before, after_off_tab_maximize)
        assert.equal(tab2_id, child.api.nvim_get_current_tabpage())

        switch_to_tab(tab1_id)
        toggle_maximize(tab1_id)
        local maximized = snapshot_tab_state(tab1_id)
        assert.is_true(maximized.is_maximized)

        switch_to_tab(tab2_id)
        toggle_maximize(tab1_id)

        local after_off_tab_restore = snapshot_tab_state(tab1_id)
        assert.same(maximized, after_off_tab_restore)
        assert.equal(tab2_id, child.api.nvim_get_current_tabpage())
    end)

    it(
        "round-trips a mixed split tree with the same buffers and focus",
        function()
            local layout = create_mixed_editor_layout()
            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)

            toggle_maximize(tab_id)
            toggle_maximize(tab_id)

            local after = snapshot_editor_layout(tab_id)
            assert.same(before, after)

            local current = child.lua([[
            return {
                bufnr = vim.api.nvim_get_current_buf(),
                cursor = vim.api.nvim_win_get_cursor(0),
            }
        ]])
            assert.equal(layout.bottom, current.bufnr)
            assert.equal(2, current.cursor[1])
        end
    )

    it(
        "restores the editor layout even with window-local options set",
        function()
            local layout = create_mixed_editor_layout()
            local statuscolumn = "%=%l%s"

            child.lua(string.format(
                [[
            local winid = vim.fn.bufwinid(%d)
            vim.api.nvim_set_option_value("statuscolumn", %q, { win = winid })
            vim.api.nvim_set_option_value("signcolumn", "yes:2", { win = winid })
            vim.api.nvim_set_option_value("number", true, { win = winid })
            vim.api.nvim_set_option_value("relativenumber", true, { win = winid })
            vim.api.nvim_set_option_value("foldcolumn", "2", { win = winid })
        ]],
                layout.bottom,
                statuscolumn
            ))
            child.flush()

            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)
            local before_count = count_editor_windows(tab_id)

            toggle_maximize(tab_id)
            toggle_maximize(tab_id)

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.equal(before_count, count_editor_windows(tab_id))
        end
    )

    it(
        "hide while maximized restores the editor layout and repeated cycles do not duplicate windows",
        function()
            create_mixed_editor_layout()
            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)
            local before_count = count_editor_windows(tab_id)

            toggle_maximize(tab_id)
            toggle_widget()

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.equal(before_count, count_editor_windows(tab_id))
            assert_no_agentic_in_editor_windows(tab_id, "After maximize + hide")

            toggle_widget()
            toggle_maximize(tab_id)
            toggle_widget()

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.equal(before_count, count_editor_windows(tab_id))
            assert_no_agentic_in_editor_windows(
                tab_id,
                "After maximize + hide + show + maximize + hide"
            )
        end
    )

    it(
        "restores bufhidden=wipe and bufhidden=delete after maximize + hide",
        function()
            local buffers = create_bufhidden_editor_layout()
            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)

            toggle_maximize(tab_id)
            toggle_widget()

            local state = child.lua(
                string.format(
                    [[
            return {
                wipe_valid = vim.api.nvim_buf_is_valid(%d),
                delete_valid = vim.api.nvim_buf_is_valid(%d),
                wipe_bufhidden = vim.bo[%d].bufhidden,
                delete_bufhidden = vim.bo[%d].bufhidden,
            }
        ]],
                    buffers.wipe,
                    buffers.delete,
                    buffers.wipe,
                    buffers.delete
                )
            )

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.is_true(state.wipe_valid)
            assert.is_true(state.delete_valid)
            assert.equal("wipe", state.wipe_bufhidden)
            assert.equal("delete", state.delete_bufhidden)
        end
    )

    it(
        "new_session clears maximize state and restores bufhidden overrides",
        function()
            local buffers = create_bufhidden_editor_layout()
            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)

            toggle_maximize(tab_id)

            child.lua([[ require("agentic").new_session() ]])
            child.flush()

            local state = child.lua(
                string.format(
                    [[
            local session = require("agentic.session_registry").sessions[%d]
            return {
                is_maximized = session.widget._maximize_state ~= nil,
                wipe_valid = vim.api.nvim_buf_is_valid(%d),
                delete_valid = vim.api.nvim_buf_is_valid(%d),
                wipe_bufhidden = vim.bo[%d].bufhidden,
                delete_bufhidden = vim.bo[%d].bufhidden,
            }
        ]],
                    tab_id,
                    buffers.wipe,
                    buffers.delete,
                    buffers.wipe,
                    buffers.delete
                )
            )

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.is_false(state.is_maximized)
            assert.is_true(state.wipe_valid)
            assert.is_true(state.delete_valid)
            assert.equal("wipe", state.wipe_bufhidden)
            assert.equal("delete", state.delete_bufhidden)
        end
    )

    it(
        "destroy_session clears maximize state and restores bufhidden overrides",
        function()
            local buffers = create_bufhidden_editor_layout()
            toggle_widget()

            local tab_id = child.api.nvim_get_current_tabpage()
            local before = snapshot_editor_layout(tab_id)

            toggle_maximize(tab_id)

            child.lua(
                string.format(
                    [[ require("agentic.session_registry").destroy_session(%d) ]],
                    tab_id
                )
            )
            child.flush()

            local state = child.lua(
                string.format(
                    [[
            return {
                session_exists = require("agentic.session_registry").sessions[%d] ~= nil,
                wipe_valid = vim.api.nvim_buf_is_valid(%d),
                delete_valid = vim.api.nvim_buf_is_valid(%d),
                wipe_bufhidden = vim.bo[%d].bufhidden,
                delete_bufhidden = vim.bo[%d].bufhidden,
            }
        ]],
                    tab_id,
                    buffers.wipe,
                    buffers.delete,
                    buffers.wipe,
                    buffers.delete
                )
            )

            assert.same(before, snapshot_editor_layout(tab_id))
            assert.is_false(state.session_exists)
            assert.is_true(state.wipe_valid)
            assert.is_true(state.delete_valid)
            assert.equal("wipe", state.wipe_bufhidden)
            assert.equal("delete", state.delete_bufhidden)
            assert_no_agentic_in_editor_windows(
                tab_id,
                "After destroy_session on a maximized widget"
            )
        end
    )

    it(
        "never restores another tab's Agentic buffers into editor windows",
        function()
            create_mixed_editor_layout()
            toggle_widget()

            local tab1_id = child.api.nvim_get_current_tabpage()
            toggle_maximize(tab1_id)

            child.cmd("tabnew")
            create_mixed_editor_layout()
            toggle_widget()
            local tab2_id = child.api.nvim_get_current_tabpage()

            local tab2_filetypes = get_tabpage_filetypes(tab2_id)
            assert.is_true(#tab2_filetypes >= 2)

            switch_to_tab(tab1_id)
            toggle_widget()

            assert_no_agentic_in_editor_windows(
                tab1_id,
                "Tab1 after hiding a maximized widget while Tab2 also has Agentic open"
            )
        end
    )

    it("aborts maximize cleanly when a quickfix window is open", function()
        create_mixed_editor_layout()
        child.lua([[
            vim.fn.setqflist({
                {
                    bufnr = vim.api.nvim_get_current_buf(),
                    lnum = 1,
                    col = 1,
                    text = "quickfix entry",
                },
            })
            vim.cmd("copen")
        ]])
        child.flush()

        toggle_widget()

        local tab_id = child.api.nvim_get_current_tabpage()
        local before = snapshot_tab_state(tab_id)

        toggle_maximize(tab_id)

        local after = snapshot_tab_state(tab_id)
        assert.same(before, after)
        assert.is_false(after.is_maximized)

        local filetypes = get_tabpage_filetypes(tab_id)
        assert.is_true(vim.tbl_contains(filetypes, "qf"))
        assert.is_true(vim.tbl_contains(filetypes, "AgenticChat"))
    end)
end)
