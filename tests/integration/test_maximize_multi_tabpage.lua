--- @diagnostic disable: redundant-parameter, unnecessary-if
local assert = require("tests.helpers.assert")
local Child = require("tests.helpers.child")

--- Agentic widget filetypes that should NEVER appear as editor/code windows
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

    --- Gets sorted filetypes for all windows in the given tabpage
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

    --- Assert that no window on the given tabpage displays an Agentic widget buffer
    --- @param tabpage number
    --- @param msg string|nil
    local function assert_no_agentic_in_code_windows(tabpage, msg)
        local winids = child.api.nvim_tabpage_list_wins(tabpage)
        for _, winid in ipairs(winids) do
            local bufnr = child.api.nvim_win_get_buf(winid)
            local ft =
                child.lua_get(string.format([[vim.bo[%d].filetype]], bufnr))
            if AGENTIC_FILETYPES[ft] then
                error(
                    string.format(
                        "%s: found Agentic filetype '%s' in window %d (buf %d) on tabpage %s",
                        msg or "Agentic buffer leaked into code window",
                        ft,
                        winid,
                        bufnr,
                        tostring(tabpage)
                    )
                )
            end
        end
    end

    before_each(function()
        child.setup()
    end)

    after_each(function()
        child.stop()
    end)

    it(
        "maximize then hide does not leak prompt buffer into code window (single tab)",
        function()
            -- Open widget on tab 1
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Verify widget is open: should have empty ft, AgenticChat, AgenticInput
            local filetypes = get_tabpage_filetypes(0)
            assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

            -- Maximize via direct method call
            child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]
            session.widget:_toggle_full_width()
        ]])
            child.flush()

            -- After maximize: only AgenticChat and AgenticInput should remain
            -- The empty-filetype (editor) window should be gone
            filetypes = get_tabpage_filetypes(0)
            assert.same({ "AgenticChat", "AgenticInput" }, filetypes)

            -- Now hide the widget (toggle off) while maximized
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- After hide: should have exactly 1 window, and it should NOT be an Agentic buffer
            local tab1_id = child.api.nvim_get_current_tabpage()
            local win_count = #child.api.nvim_tabpage_list_wins(tab1_id)
            assert.equal(1, win_count)
            assert_no_agentic_in_code_windows(
                tab1_id,
                "After maximize+hide on single tab"
            )
        end
    )

    it(
        "maximize on tab1, hide widget, does not show tab2 prompt in code window",
        function()
            -- Tab 1: open widget
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            local tab1_id = child.api.nvim_get_current_tabpage()

            -- Tab 1: maximize
            child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]
            session.widget:_toggle_full_width()
        ]])
            child.flush()

            -- Tab 1 should be maximized: only AgenticChat, AgenticInput
            local filetypes = get_tabpage_filetypes(tab1_id)
            assert.same({ "AgenticChat", "AgenticInput" }, filetypes)

            -- Create tab 2 and open widget there
            child.cmd("tabnew")
            local tab2_id = child.api.nvim_get_current_tabpage()
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Tab 2 should have: empty ft, AgenticChat, AgenticInput
            filetypes = get_tabpage_filetypes(tab2_id)
            assert.same({ "", "AgenticChat", "AgenticInput" }, filetypes)

            -- Switch back to tab 1
            child.lua(
                string.format(
                    [[ vim.api.nvim_set_current_tabpage(%d) ]],
                    tab1_id
                )
            )
            child.flush()

            -- Tab 1: hide widget while maximized
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Tab 1 should have exactly 1 window, no Agentic buffers
            local win_count = #child.api.nvim_tabpage_list_wins(tab1_id)
            assert.equal(1, win_count)
            assert_no_agentic_in_code_windows(
                tab1_id,
                "Tab1 after maximize+hide should not show Tab2's widget buffers"
            )
        end
    )

    it(
        "unmaximize on tab1 does not leak tab2 widget buffers when saved buffers are wiped",
        function()
            -- Open a real file buffer so we have something to maximize away
            child.cmd("edit /tmp/agentic_test_maximize.txt")
            child.flush()

            -- Tab 1: open widget
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            local tab1_id = child.api.nvim_get_current_tabpage()

            -- Tab 1: maximize
            child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]
            session.widget:_toggle_full_width()
        ]])
            child.flush()

            -- Create tab 2 with widget
            child.cmd("tabnew")
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Wipe the file buffer that was saved during maximize on tab 1
            child.lua([[
            for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                local name = vim.api.nvim_buf_get_name(bufnr)
                if name:match("agentic_test_maximize") then
                    vim.api.nvim_buf_delete(bufnr, { force = true })
                end
            end
        ]])
            child.flush()

            -- Switch back to tab 1
            child.lua(
                string.format(
                    [[ vim.api.nvim_set_current_tabpage(%d) ]],
                    tab1_id
                )
            )
            child.flush()

            -- Tab 1: unmaximize — saved buffer is gone, should use fallback
            child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]
            session.widget:_toggle_full_width()
        ]])
            child.flush()

            -- The restored/fallback window should NOT be an Agentic buffer from tab 2.
            -- Tab 1 should have: AgenticChat, AgenticInput (its own widget) + at least 1 non-agentic window.
            -- The non-agentic window should be a scratch buffer or restored file, NOT another tab's widget.
            local non_widget_fts = child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]
            local widget_bufs = {}
            for _, bufnr in pairs(session.widget.buf_nrs) do
                widget_bufs[bufnr] = true
            end
            local result = {}
            for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tab_id)) do
                local bufnr = vim.api.nvim_win_get_buf(winid)
                if not widget_bufs[bufnr] then
                    table.insert(result, vim.bo[bufnr].filetype)
                end
            end
            return result
        ]])

            -- There should be at least 1 non-widget window
            assert.is_true(#non_widget_fts >= 1)
            -- And none of them should be Agentic filetypes (from any tab)
            for _, ft in ipairs(non_widget_fts) do
                assert.is_false(
                    AGENTIC_FILETYPES[ft] or false,
                    "Non-widget window on Tab 1 has Agentic filetype: " .. ft
                )
            end
        end
    )

    it(
        "find_first_non_widget_window ignores other tab's widget buffers",
        function()
            -- Tab 1: open widget
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            local tab1_id = child.api.nvim_get_current_tabpage()

            -- Create tab 2 with widget
            child.cmd("tabnew")
            child.lua([[ require("agentic").toggle() ]])
            child.flush()

            -- Switch back to tab 1
            child.lua(
                string.format(
                    [[ vim.api.nvim_set_current_tabpage(%d) ]],
                    tab1_id
                )
            )
            child.flush()

            -- Force a non-widget window on tab 1 to display tab 2's input buffer
            -- (simulating the bug where a cross-tab buffer leaks in)
            local result = child.lua([[
            local tab_id = vim.api.nvim_get_current_tabpage()
            local session = require("agentic.session_registry").sessions[tab_id]

            -- Find the non-widget window on tab 1
            local fallback_winid = session.widget:find_first_non_widget_window()
            if not fallback_winid then
                return { error = "no non-widget window found" }
            end

            -- Get tab 2's input buffer
            local all_tabs = vim.api.nvim_list_tabpages()
            local other_tab = nil
            for _, t in ipairs(all_tabs) do
                if t ~= tab_id then
                    other_tab = t
                    break
                end
            end

            if not other_tab then
                return { error = "no other tab found" }
            end

            local other_session = require("agentic.session_registry").sessions[other_tab]
            if not other_session then
                return { error = "no session on other tab" }
            end

            local other_input_buf = other_session.widget.buf_nrs.input

            -- Set the non-widget window to show tab 2's input buffer
            vim.wo[fallback_winid].winfixbuf = false
            vim.api.nvim_win_set_buf(fallback_winid, other_input_buf)

            -- Now try to find non-widget window again
            local found = session.widget:find_first_non_widget_window()

            return {
                found_winid = found,
                injected_winid = fallback_winid,
                other_input_buf = other_input_buf,
            }
        ]])

            -- find_first_non_widget_window should NOT return the window showing tab 2's input buffer
            -- If it does, that's the bug: it doesn't recognize cross-tab widget buffers
            if result and result.found_winid then
                -- If it found a window, it should NOT be the one we injected with the other tab's buffer
                assert.are_not.equal(result.found_winid, result.injected_winid)
            end
            -- If it returns nil, that's correct behavior (no valid non-widget window)
        end
    )
end)
