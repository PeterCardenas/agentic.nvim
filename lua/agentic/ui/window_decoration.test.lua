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

    --- @diagnostic disable-next-line: invisible
    describe("_set_buffer_name", function()
        --- @type integer[]
        local extra_bufs

        --- @param path string
        --- @return string normalized
        local function normalize(path)
            return vim.fn.resolve(vim.fn.fnamemodify(path, ":p"))
        end

        --- @param expected string
        --- @param target_bufnr integer
        local function assert_buf_name(expected, target_bufnr)
            assert.equal(
                normalize(expected),
                normalize(vim.api.nvim_buf_get_name(target_bufnr))
            )
        end

        --- @return integer bufnr
        local function new_buf()
            local created = vim.api.nvim_create_buf(false, true)
            table.insert(extra_bufs, created)
            return created
        end

        before_each(function()
            extra_bufs = {}
        end)

        after_each(function()
            for _, created in ipairs(extra_bufs) do
                pcall(vim.api.nvim_buf_delete, created, { force = true })
            end
        end)

        it("sets the name when no other buffer holds it", function()
            local target = new_buf()
            local name = vim.fn.tempname() .. " 󰻞 Agentic Chat"

            assert.is_true(WindowDecoration._set_buffer_name(target, name))

            assert_buf_name(name, target)
        end)

        it(
            "renames the colliding buffer to <name>-old-1 and still names the target",
            function()
                local name = vim.fn.tempname() .. " 󰻞 Agentic Chat"
                local stale = new_buf()
                vim.api.nvim_buf_set_name(stale, name)

                local target = new_buf()
                assert.is_true(WindowDecoration._set_buffer_name(target, name))

                assert_buf_name(name, target)
                assert_buf_name(name .. "-old-1", stale)
            end
        )

        it("picks the lowest free -old-N suffix", function()
            local name = vim.fn.tempname() .. " 󰦨 Prompt (Tab 2)"
            local old1 = new_buf()
            vim.api.nvim_buf_set_name(old1, name .. "-old-1")
            local old2 = new_buf()
            vim.api.nvim_buf_set_name(old2, name .. "-old-2")

            local stale = new_buf()
            vim.api.nvim_buf_set_name(stale, name)

            local target = new_buf()
            assert.is_true(WindowDecoration._set_buffer_name(target, name))

            assert_buf_name(name, target)
            assert_buf_name(name .. "-old-3", stale)
            assert_buf_name(name .. "-old-1", old1)
            assert_buf_name(name .. "-old-2", old2)
        end)

        it("is a no-op when the buffer already holds the name", function()
            local target = new_buf()
            local name = vim.fn.tempname() .. " 󰻞 Agentic Chat"
            vim.api.nvim_buf_set_name(target, name)
            set_name_spy:reset()

            assert.is_true(WindowDecoration._set_buffer_name(target, name))

            assert.spy(set_name_spy).was.called(0)
            assert_buf_name(name, target)
        end)

        it(
            "render_header still names the buffer when a stale buffer squats on the name",
            function()
                -- Simulates a `:mksession` restore: a leftover buffer already
                -- carries the agentic name the new widget buffer wants.
                WindowDecoration.render_header(bufnr, "chat")
                local wanted = vim.api.nvim_buf_get_name(bufnr)
                assert.is_not.equal("", wanted)

                local stale = bufnr
                local target = new_buf()
                local target_winid = vim.api.nvim_open_win(target, true, {
                    relative = "editor",
                    width = 20,
                    height = 5,
                    row = 0,
                    col = 0,
                })

                WindowDecoration.render_header(target, "chat")
                vim.api.nvim_win_close(target_winid, true)

                -- The new widget buffer wins the name; the squatter is moved
                -- aside deterministically instead of the rename being skipped.
                -- The exact -old-N index depends on buffers other tests in
                -- this shared nvim left behind, so only the shape is asserted;
                -- index selection is covered by the unit cases above.
                assert_buf_name(wanted, target)
                local stale_name = vim.api.nvim_buf_get_name(stale)
                assert.is_not_nil(
                    stale_name:match(vim.pesc(wanted) .. "%-old%-%d+$")
                )
            end
        )

        it(
            "render_header retries the rename after a failure instead of caching it",
            function()
                local Logger = require("agentic.utils.logger")
                local notify_stub = spy.stub(Logger, "notify")

                -- Real API, reached through the outer spy so its counts stay
                -- meaningful.
                local real_set_name = vim.api.nvim_buf_set_name
                local fail_next = true
                local set_name_stub = spy.stub(vim.api, "nvim_buf_set_name")
                set_name_stub:invokes(function(target_bufnr, name)
                    if fail_next then
                        fail_next = false
                        error("Vim:E95: Buffer with this name already exists")
                    end
                    return real_set_name(target_bufnr, name)
                end)

                WindowDecoration.render_header(bufnr, "chat")

                -- Rename failed: buffer unnamed, failure surfaced, and the
                -- name must NOT be recorded as applied.
                assert.equal("", vim.api.nvim_buf_get_name(bufnr))
                assert.spy(notify_stub).was.called(1)
                assert.is_nil(vim.b[bufnr].agentic_buffer_name)

                -- Same header text again: the old code short-circuited on the
                -- cache here and left the buffer unnamed forever.
                WindowDecoration.render_header(bufnr, "chat")

                set_name_stub:revert()
                notify_stub:revert()

                assert.is_not.equal("", vim.api.nvim_buf_get_name(bufnr))
                assert.is_not_nil(vim.b[bufnr].agentic_buffer_name)
                assert.is_nil(vim.b[bufnr].agentic_buffer_name_error)
            end
        )

        it("reports a persistent rename failure only once", function()
            local Logger = require("agentic.utils.logger")
            local notify_stub = spy.stub(Logger, "notify")
            local set_name_stub = spy.stub(vim.api, "nvim_buf_set_name")
            set_name_stub:invokes(function()
                error("Vim:E95: Buffer with this name already exists")
            end)

            WindowDecoration.render_header(bufnr, "chat")
            WindowDecoration.render_header(bufnr, "chat")
            WindowDecoration.render_header(bufnr, "chat")

            set_name_stub:revert()
            notify_stub:revert()

            -- Retried every time, but de-duplicated per buffer+name so the
            -- retry loop does not spam notifications.
            assert.spy(notify_stub).was.called(1)
            assert.is_nil(vim.b[bufnr].agentic_buffer_name)
        end)
    end)
end)
