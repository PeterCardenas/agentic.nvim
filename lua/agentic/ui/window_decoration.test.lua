local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local Config = require("agentic.config")

describe("agentic.ui.WindowDecoration", function()
    --- @type agentic.ui.WindowDecoration
    local WindowDecoration
    --- @type TestStub
    local schedule_stub
    --- @type TestSpy
    local set_option_spy
    --- @type TestSpy
    local set_name_spy
    --- @type TestSpy
    local cmd_spy
    --- @type integer
    local bufnr
    --- @type integer
    local winid
    local original_headers

    before_each(function()
        package.loaded["agentic.ui.window_decoration"] = nil
        WindowDecoration = require("agentic.ui.window_decoration")

        original_headers = Config.headers
        Config.headers = nil

        schedule_stub = spy.stub(vim, "schedule")
        schedule_stub:invokes(function(fn)
            fn()
        end)

        set_option_spy = spy.on(vim.api, "nvim_set_option_value")
        set_name_spy = spy.on(vim.api, "nvim_buf_set_name")
        cmd_spy = spy.on(vim, "cmd")

        bufnr = vim.api.nvim_create_buf(false, true)
        winid = vim.api.nvim_open_win(bufnr, true, {
            relative = "editor",
            width = 20,
            height = 5,
            row = 0,
            col = 0,
        })

        vim.t[vim.api.nvim_get_current_tabpage()].agentic_headers = nil
    end)

    after_each(function()
        Config.headers = original_headers

        schedule_stub:revert()
        set_option_spy:revert()
        set_name_spy:revert()
        cmd_spy:revert()

        if winid and vim.api.nvim_win_is_valid(winid) then
            vim.api.nvim_win_close(winid, true)
        end
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
    end)

    it(
        "skips redundant winbar redraws when the header text is unchanged",
        function()
            WindowDecoration.render_header(bufnr, "chat")
            WindowDecoration.render_header(bufnr, "chat")

            assert.spy(set_option_spy).was.called(1)
            assert.spy(set_name_spy).was.called(1)
            assert.spy(cmd_spy).was.called(1)
            local first_cmd = assert.not_nil(cmd_spy.calls[1])
            assert.equal("redrawstatus!", first_cmd[1])
        end
    )

    it("re-renders when the resolved header text changes", function()
        WindowDecoration.render_header(bufnr, "chat")
        WindowDecoration.render_header(bufnr, "chat", "Mode: Plan")

        assert.spy(set_option_spy).was.called(2)
        assert.spy(set_name_spy).was.called(2)
        assert.spy(cmd_spy).was.called(2)
        local first_cmd = assert.not_nil(cmd_spy.calls[1])
        local second_cmd = assert.not_nil(cmd_spy.calls[2])
        assert.equal("redrawstatus!", first_cmd[1])
        assert.equal("redrawstatus!", second_cmd[1])
    end)
end)
