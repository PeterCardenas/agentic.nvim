local assert = require("tests.helpers.assert")
local BufHelpers = require("agentic.utils.buf_helpers")
local spy = require("tests.helpers.spy")

describe("agentic.ui.StatusAnimation", function()
    --- @type agentic.ui.StatusAnimation
    local StatusAnimation
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    --- @type agentic.ui.StatusAnimation
    local animation

    before_each(function()
        StatusAnimation = require("agentic.ui.status_animation")

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 20,
            height = 5,
            row = 0,
            col = 0,
        })

        vim.wo[winid].wrap = true
        vim.wo[winid].smoothscroll = true
        vim.wo[winid].linebreak = false
        vim.wo[winid].breakindent = false

        animation = StatusAnimation:new(bufnr)
    end)

    after_each(function()
        animation:stop()

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it(
        "keeps the spinner visible when the first render pushes the tail off-screen",
        function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "header 1",
                "header 2",
                "header 3",
                "header 4",
                "agent: " .. string.rep("x", 20),
            })
            BufHelpers.scroll_window_to_bottom(winid)

            local before = vim.api.nvim_win_call(winid, function()
                return vim.fn.winsaveview()
            end)

            animation:start("thinking")

            local after = vim.api.nvim_win_call(winid, function()
                return vim.fn.winsaveview()
            end)

            assert.is_true(BufHelpers.is_window_bottom_visible(winid))
            assert.is_true(
                after.topline > before.topline or after.skipcol > before.skipcol
            )
        end
    )

    it(
        "does not auto-scroll when the user is already away from the bottom",
        function()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
                "line 1",
                "line 2",
                "line 3",
                "line 4",
                "line 5",
                "line 6",
                "line 7",
                "line 8",
            })
            vim.api.nvim_win_set_cursor(winid, { 1, 0 })

            local before = vim.api.nvim_win_call(winid, function()
                return vim.fn.winsaveview()
            end)

            animation:start("thinking")

            local after = vim.api.nvim_win_call(winid, function()
                return vim.fn.winsaveview()
            end)

            assert.are.same(before, after)
        end
    )

    it("does not restart the spinner when the state is unchanged", function()
        local stop_spy = spy.on(StatusAnimation, "stop")
        local render_spy = spy.on(StatusAnimation, "_render_frame")

        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "agent output" })

        animation:start("thinking")
        animation:start("thinking")

        assert.spy(stop_spy).was.called(1)
        assert.spy(render_spy).was.called(1)

        render_spy:revert()
        stop_spy:revert()
    end)
end)
