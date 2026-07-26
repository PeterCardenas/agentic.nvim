--- @diagnostic disable: need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local ChatWidgetGf = require("agentic.ui.chat_widget_gf")
local ChatWidget = require("agentic.ui.chat_widget")
local FileList = require("agentic.ui.file_list")
local Logger = require("agentic.utils.logger")

--- Creates a real, readable file on disk so `filereadable`/resolution checks
--- have something genuine to find.
--- @param lines string[]|nil
--- @return string abs_path
local function create_test_file(lines)
    local path = vim.fs.joinpath(
        vim.uv.os_tmpdir() or "/tmp",
        "agentic-gf-unit-" .. tostring(vim.uv.hrtime()) .. ".lua"
    )
    vim.fn.writefile(lines or { "line1", "line2", "line3" }, path)
    return path
end

--- Finds the (1-indexed) start column of `sub` in `s`, failing the test if
--- not found. Used to keep cursor columns in sync with the literal test
--- strings instead of hardcoding brittle offsets.
--- @param s string
--- @param sub string
--- @param init integer|nil
--- @return integer
local function must_find(s, sub, init)
    local pos = s:find(sub, init or 1, true)
    assert.is_not_nil(pos)
    return pos --[[@as integer]]
end

describe("agentic.ui.chat_widget_gf", function()
    describe("find_path_candidates", function()
        it("finds a plain path token with no suffix", function()
            local candidates =
                ChatWidgetGf.find_path_candidates("lua/foo.lua", 1)
            assert.equal(1, #candidates)
            assert.equal("lua/foo.lua", candidates[1].text)
            assert.is_nil(candidates[1].target_line)
            assert.is_nil(candidates[1].target_col)
        end)

        it("captures a trailing :LINE suffix", function()
            local candidates = ChatWidgetGf.find_path_candidates(
                "see lua/foo.lua:42 for details",
                5
            )
            assert.equal(1, #candidates)
            assert.equal("lua/foo.lua", candidates[1].text)
            assert.equal(42, candidates[1].target_line)
            assert.is_nil(candidates[1].target_col)
        end)

        it("captures a trailing :LINE:COL suffix", function()
            local candidates =
                ChatWidgetGf.find_path_candidates("lua/foo.lua:42:7", 1)
            assert.equal(1, #candidates)
            assert.equal(42, candidates[1].target_line)
            assert.equal(7, candidates[1].target_col)
        end)

        it("ignores a non-numeric suffix", function()
            local candidates =
                ChatWidgetGf.find_path_candidates("lua/foo.lua:not-a-line", 1)
            assert.equal(1, #candidates)
            assert.is_nil(candidates[1].target_line)
        end)

        it(
            "skips a lone bullet '-' with nothing path-like on the line when the cursor is elsewhere",
            function()
                -- Cursor at column 4 (whitespace), not on the "-" itself.
                local candidates = ChatWidgetGf.find_path_candidates("-   ", 4)
                assert.equal(0, #candidates)
            end
        )

        it(
            "finds the real path in file_list's bullet-prefixed rendering when the cursor is not on the bullet",
            function()
                -- Cursor at column 4 (whitespace between bullet and path).
                local candidates =
                    ChatWidgetGf.find_path_candidates("-   /tmp/foo.lua", 4)
                assert.equal(1, #candidates)
                assert.equal("/tmp/foo.lua", candidates[1].text)
            end
        )

        it(
            "still includes the bullet as a raw candidate when the cursor sits on it (resolution falls through to the real path)",
            function()
                local candidates =
                    ChatWidgetGf.find_path_candidates("-   /tmp/foo.lua", 1)
                assert.equal(2, #candidates)
                assert.equal("-", candidates[1].text)
                assert.equal("/tmp/foo.lua", candidates[2].text)
            end
        )

        it(
            "skips the mid-line '-' separator used by diagnostics_list",
            function()
                local line_text = "X /tmp/foo.lua:3:1 - some message"
                -- Cursor at column 2 (space between the icon and the path).
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, 2)
                assert.equal(1, #candidates)
                assert.equal("/tmp/foo.lua", candidates[1].text)
                assert.equal(3, candidates[1].target_line)
                assert.equal(1, candidates[1].target_col)
            end
        )

        it("finds multiple candidates on the same line", function()
            local line_text = "compare a/foo.lua with b/bar.lua"
            -- Cursor on the space right after "compare" -- not on any
            -- token, so the cursor-bypass rule doesn't turn the bare prose
            -- word "compare" into a spurious third candidate.
            local candidates = ChatWidgetGf.find_path_candidates(line_text, 8)
            assert.equal(2, #candidates)
            assert.equal("a/foo.lua", candidates[1].text)
            assert.equal("b/bar.lua", candidates[2].text)
        end)

        it(
            "always includes the token under the cursor even if it doesn't look path-like (Makefile-style)",
            function()
                local line_text = "See Makefile for details"
                local cursor_col = must_find(line_text, "Makefile")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("Makefile", candidates[1].text)
            end
        )

        it(
            "trims a trailing period but keeps the untrimmed form in raw_text",
            function()
                local line_text = "See /tmp/foo.lua. Done."
                local cursor_col = must_find(line_text, "/tmp/foo.lua")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("/tmp/foo.lua", candidates[1].text)
                assert.equal("/tmp/foo.lua.", candidates[1].raw_text)
            end
        )

        it(
            "trims a trailing comma but keeps the untrimmed form in raw_text",
            function()
                local line_text = "Files: /tmp/foo.lua, more"
                local cursor_col = must_find(line_text, "/tmp/foo.lua")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("/tmp/foo.lua", candidates[1].text)
                assert.equal("/tmp/foo.lua,", candidates[1].raw_text)
            end
        )

        it(
            "captures a full accented path component instead of truncating at the multi-byte character",
            function()
                local line_text = "See café/foo.lua now"
                local cursor_col = must_find(line_text, "café")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("café/foo.lua", candidates[1].text)
            end
        )

        it(
            "captures a full CJK path component instead of truncating at the multi-byte character",
            function()
                local line_text = "See 文档/foo.lua now"
                local cursor_col = must_find(line_text, "文档")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("文档/foo.lua", candidates[1].text)
            end
        )

        it(
            "still excludes a genuine multi-byte icon glyph as a candidate when the cursor is elsewhere",
            function()
                -- "❌" is a real icon used by diagnostics_list.lua
                -- (Config.diagnostic_icons.error). It contains no "/", ".",
                -- or ASCII alphanumeric, so it must not qualify on its own
                -- shape merits -- only the cursor-bypass (tested separately
                -- below) can make it a candidate.
                local line_text = "❌ /tmp/foo.lua:3:1 - some message"
                local cursor_col = must_find(line_text, "/tmp/foo.lua")
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, cursor_col)
                assert.equal(1, #candidates)
                assert.equal("/tmp/foo.lua", candidates[1].text)
            end
        )

        it(
            "includes a genuine multi-byte icon glyph as a raw candidate when the cursor sits on it",
            function()
                local line_text = "❌ /tmp/foo.lua:3:1 - some message"
                -- Cursor on the icon itself (its first byte).
                local candidates =
                    ChatWidgetGf.find_path_candidates(line_text, 1)
                assert.equal(2, #candidates)
                assert.equal("❌", candidates[1].text)
                assert.equal("/tmp/foo.lua", candidates[2].text)
            end
        )
    end)

    describe("resolve_absolute_path", function()
        it("returns nil for nil input", function()
            assert.is_nil(ChatWidgetGf.resolve_absolute_path(nil))
        end)

        it("returns nil for empty input", function()
            assert.is_nil(ChatWidgetGf.resolve_absolute_path(""))
        end)

        it("resolves an absolute path unchanged", function()
            local result = ChatWidgetGf.resolve_absolute_path("/tmp/foo.lua")
            assert.equal("/tmp/foo.lua", result)
        end)

        it(
            "resolves a relative path against the current working directory",
            function()
                local cwd = vim.fn.getcwd()
                local result =
                    ChatWidgetGf.resolve_absolute_path("relative/foo.lua")
                assert.equal(cwd .. "/relative/foo.lua", result)
            end
        )

        it("expands ~ to the home directory", function()
            local home = vim.fn.expand("~")
            local result = ChatWidgetGf.resolve_absolute_path("~/foo.lua")
            assert.equal(home .. "/foo.lua", result)
        end)
    end)

    describe("resolve_gf_target", function()
        it("resolves the only candidate on the line", function()
            local file_path = create_test_file()
            local abs_path, target_line, target_col =
                ChatWidgetGf.resolve_gf_target(file_path .. ":2", 1)
            assert.equal(file_path, abs_path)
            assert.equal(2, target_line)
            assert.is_nil(target_col)
        end)

        it(
            "selects the occurrence nearest the cursor for a path repeated with different line numbers",
            function()
                local file_path = create_test_file()
                local line_text = file_path .. ":10 vs " .. file_path .. ":20"

                -- Cursor inside the FIRST occurrence -> line 10.
                local _, first_line =
                    ChatWidgetGf.resolve_gf_target(line_text, 2)
                assert.equal(10, first_line)

                -- Cursor inside the SECOND occurrence -> line 20.
                local second_occurrence_start =
                    must_find(line_text, file_path, #file_path + 1)
                local _, second_line = ChatWidgetGf.resolve_gf_target(
                    line_text,
                    second_occurrence_start + 2
                )
                assert.equal(20, second_line)
            end
        )

        it(
            "falls back to another candidate when the nearest one does not resolve",
            function()
                local real_path = create_test_file()
                local fake_path = "/tmp/agentic-gf-nope-"
                    .. tostring(vim.uv.hrtime())
                    .. ".lua"
                local line_text = fake_path .. " " .. real_path

                -- Cursor sits on the unresolvable (nearest) candidate.
                local abs_path = ChatWidgetGf.resolve_gf_target(line_text, 2)
                assert.equal(real_path, abs_path)
            end
        )

        it(
            "prefers the nearer real file over a farther one, even when an unresolvable token sits closer to the cursor",
            function()
                -- Reproduces the exact scenario reported: two real files
                -- with a prose token ("e.g.") between them; the cursor sits
                -- on the prose token, closer to the SECOND file. The
                -- farther-but-first-in-document-order file must NOT win.
                local file_a = create_test_file()
                local file_b = create_test_file()
                local line_text = file_a .. " e.g. " .. file_b

                -- Cursor on the LAST character of "e.g." -- 2 bytes from
                -- file_b's start, 5 bytes from file_a's end, matching the
                -- reported reproduction exactly.
                local eg_start = must_find(line_text, "e.g.")
                local cursor_col = eg_start + 3

                local abs_path =
                    ChatWidgetGf.resolve_gf_target(line_text, cursor_col)
                assert.equal(file_b, abs_path)
            end
        )

        it(
            "resolves the path when the cursor sits on file_list's leading bullet decoration",
            function()
                local file_path = create_test_file()
                local list_bufnr = vim.api.nvim_create_buf(false, true)
                local file_list = FileList:new(list_bufnr, function() end)
                file_list:add(file_path)

                local line_text =
                    vim.api.nvim_buf_get_lines(list_bufnr, 0, 1, false)[1]

                -- Column 1 is the leading "-" bullet, not the path.
                local abs_path = ChatWidgetGf.resolve_gf_target(line_text, 1)
                assert.equal(file_path, abs_path)

                vim.api.nvim_buf_delete(list_bufnr, { force = true })
            end
        )

        it(
            "resolves the path around diagnostics_list's icon and ' - ' message separator",
            function()
                local file_path = create_test_file()
                local line_text = string.format(
                    "%s %s:%d:%d - %s",
                    "X",
                    file_path,
                    3,
                    1,
                    "some message here"
                )

                -- Cursor on the leading icon decoration, not the path.
                local abs_path, target_line, target_col =
                    ChatWidgetGf.resolve_gf_target(line_text, 1)
                assert.equal(file_path, abs_path)
                assert.equal(3, target_line)
                assert.equal(1, target_col)
            end
        )

        it(
            "falls through from a genuine multi-byte icon glyph under the cursor to the real path",
            function()
                -- Same as above, but with the ACTUAL multi-byte icon
                -- (Config.diagnostic_icons.error) instead of an ASCII
                -- stand-in, to prove the cursor-bypass candidate it now
                -- produces (see find_path_candidates tests) still loses the
                -- distance-ordered resolution race to the real file.
                local file_path = create_test_file()
                local line_text = string.format(
                    "%s %s:%d:%d - %s",
                    "❌",
                    file_path,
                    3,
                    1,
                    "some message here"
                )

                -- Cursor on the icon's first byte.
                local abs_path, target_line, target_col =
                    ChatWidgetGf.resolve_gf_target(line_text, 1)
                assert.equal(file_path, abs_path)
                assert.equal(3, target_line)
                assert.equal(1, target_col)
            end
        )

        it("resolves a path with an accented directory component", function()
            local dir = vim.fs.joinpath(
                vim.uv.os_tmpdir() or "/tmp",
                "agentic-gf-unit-café-" .. tostring(vim.uv.hrtime())
            )
            vim.fn.mkdir(dir, "p")
            local file_path = vim.fs.joinpath(dir, "foo.lua")
            vim.fn.writefile({ "line1" }, file_path)

            local line_text = "See " .. file_path .. " now"
            local cursor_col = must_find(line_text, "café")

            local abs_path =
                ChatWidgetGf.resolve_gf_target(line_text, cursor_col)
            assert.equal(file_path, abs_path)
        end)

        it("resolves a path with a CJK directory component", function()
            local dir = vim.fs.joinpath(
                vim.uv.os_tmpdir() or "/tmp",
                "agentic-gf-unit-文档-" .. tostring(vim.uv.hrtime())
            )
            vim.fn.mkdir(dir, "p")
            local file_path = vim.fs.joinpath(dir, "foo.lua")
            vim.fn.writefile({ "line1" }, file_path)

            local line_text = "See " .. file_path .. " now"
            local cursor_col = must_find(line_text, "文档")

            local abs_path =
                ChatWidgetGf.resolve_gf_target(line_text, cursor_col)
            assert.equal(file_path, abs_path)
        end)

        it(
            "resolves a path followed by a trailing period at the end of a sentence",
            function()
                local file_path = create_test_file()
                local line_text = "See " .. file_path .. ". Done."
                local cursor_col = must_find(line_text, file_path)

                local abs_path =
                    ChatWidgetGf.resolve_gf_target(line_text, cursor_col)
                assert.equal(file_path, abs_path)
            end
        )

        it("resolves a comma-separated list of two real paths", function()
            local file_a = create_test_file()
            local file_b = create_test_file()
            local line_text = "Files: " .. file_a .. ", " .. file_b

            local cursor_on_a = must_find(line_text, file_a)
            local abs_path_a =
                ChatWidgetGf.resolve_gf_target(line_text, cursor_on_a)
            assert.equal(file_a, abs_path_a)

            local cursor_on_b = must_find(line_text, file_b)
            local abs_path_b =
                ChatWidgetGf.resolve_gf_target(line_text, cursor_on_b)
            assert.equal(file_b, abs_path_b)
        end)

        it(
            "resolves an extensionless filename under the cursor (Makefile-style)",
            function()
                -- Create a real extensionless file (mirroring Makefile,
                -- Dockerfile, LICENSE) in a scratch directory, and
                -- temporarily switch cwd there so the bare filename in the
                -- test line resolves relative to it.
                local original_cwd = vim.fn.getcwd()
                local dir = vim.fs.joinpath(
                    vim.uv.os_tmpdir() or "/tmp",
                    "agentic-gf-makefile-" .. tostring(vim.uv.hrtime())
                )
                vim.fn.mkdir(dir, "p")
                local makefile_path = vim.fs.joinpath(dir, "Makefile")
                vim.fn.writefile({ "all:", "\techo hi" }, makefile_path)

                vim.cmd("cd " .. vim.fn.fnameescape(dir))
                local ok, abs_path = pcall(function()
                    local line_text = "See Makefile for details"
                    local cursor_col = must_find(line_text, "Makefile")
                    return ChatWidgetGf.resolve_gf_target(line_text, cursor_col)
                end)
                vim.cmd("cd " .. vim.fn.fnameescape(original_cwd))

                assert.is_true(ok)
                assert.equal(makefile_path, abs_path)
            end
        )

        it(
            "does not resolve a bare prose token that merely looks like a path",
            function()
                local line_text = "v1.2.3"
                local abs_path, _, _, attempted =
                    ChatWidgetGf.resolve_gf_target(line_text, 1)
                assert.is_nil(abs_path)
                assert.equal("v1.2.3", attempted)
            end
        )

        it("returns nil for a directory path", function()
            local dir = vim.uv.os_tmpdir() or "/tmp"
            local abs_path = ChatWidgetGf.resolve_gf_target(dir, 1)
            assert.is_nil(abs_path)
        end)

        it(
            "returns nil and the attempted text when nothing on the line resolves",
            function()
                local suffix = tostring(vim.uv.hrtime())
                local fake1 = "/tmp/agentic-gf-nope-1-" .. suffix .. ".lua"
                local fake2 = "/tmp/agentic-gf-nope-2-" .. suffix .. ".lua"
                local line_text = fake1 .. " " .. fake2

                local abs_path, _, _, attempted =
                    ChatWidgetGf.resolve_gf_target(line_text, 1)
                assert.is_nil(abs_path)
                assert.equal(fake1, attempted)
            end
        )
    end)

    describe("ChatWidget:_goto_file_under_cursor", function()
        --- @type agentic.ui.ChatWidget
        local widget
        local tab_page_id
        local original_winid
        --- @type TestSpy
        local notify_spy

        before_each(function()
            vim.cmd("tabnew")
            tab_page_id = vim.api.nvim_get_current_tabpage()
            original_winid = vim.api.nvim_get_current_win()
            widget = ChatWidget:new(tab_page_id, function() end)
            notify_spy = spy.on(Logger, "notify")
        end)

        after_each(function()
            notify_spy:revert()
            pcall(function()
                vim.wo[original_winid].winfixbuf = false
            end)
            pcall(function()
                widget:destroy()
            end)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)

        --- @param content string
        local function set_chat_line(content)
            vim.bo[widget.buf_nrs.chat].modifiable = true
            vim.api.nvim_buf_set_lines(
                widget.buf_nrs.chat,
                0,
                -1,
                false,
                { content }
            )
            vim.bo[widget.buf_nrs.chat].modifiable = false
        end

        --- Focuses the chat window such that `winnr('#')` (the alternate
        --- window) deterministically points at `original_winid` -- matching
        --- the real "user was editing, then jumped to chat" flow that
        --- `_get_preferred_editor_focus_winid` relies on.
        local function focus_chat_from_editor()
            vim.api.nvim_set_current_win(original_winid)
            vim.api.nvim_set_current_win(widget.win_nrs.chat)
            vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })
        end

        it(
            "opens a real file in the previously-focused editor window and moves focus there",
            function()
                widget:show()
                local file_path =
                    create_test_file({ "one", "two", "three", "four" })
                set_chat_line(file_path .. ":3")
                focus_chat_from_editor()

                widget:_goto_file_under_cursor()

                local current_win = vim.api.nvim_get_current_win()
                local current_buf = vim.api.nvim_get_current_buf()
                assert.equal(original_winid, current_win)
                assert.equal(file_path, vim.api.nvim_buf_get_name(current_buf))
                assert.same({ 3, 0 }, vim.api.nvim_win_get_cursor(current_win))
            end
        )

        it(
            "warns and does not open a window when the path cannot be resolved",
            function()
                widget:show()
                local unresolvable = "/tmp/agentic-gf-does-not-exist-"
                    .. tostring(vim.uv.hrtime())
                    .. ".lua"
                set_chat_line(unresolvable)
                focus_chat_from_editor()

                widget:_goto_file_under_cursor()

                assert.is_true(notify_spy.call_count >= 1)
                local last_call = notify_spy.calls[notify_spy.call_count]
                assert.equal(vim.log.levels.WARN, last_call[2])
                assert.equal(
                    widget.win_nrs.chat,
                    vim.api.nvim_get_current_win()
                )
            end
        )

        it("warns and does not navigate for a directory path", function()
            widget:show()
            set_chat_line(vim.uv.os_tmpdir() or "/tmp")
            focus_chat_from_editor()

            widget:_goto_file_under_cursor()

            assert.is_true(notify_spy.call_count >= 1)
            local last_call = notify_spy.calls[notify_spy.call_count]
            assert.equal(vim.log.levels.WARN, last_call[2])
            assert.equal(widget.win_nrs.chat, vim.api.nvim_get_current_win())
        end)

        it(
            "falls back to opening a new left window when no editor window exists",
            function()
                widget:show()
                -- Close the only non-widget window: no editor window remains.
                vim.api.nvim_win_close(original_winid, true)

                local file_path = create_test_file()
                set_chat_line(file_path)
                vim.api.nvim_set_current_win(widget.win_nrs.chat)
                vim.api.nvim_win_set_cursor(widget.win_nrs.chat, { 1, 0 })

                widget:_goto_file_under_cursor()

                local current_buf = vim.api.nvim_get_current_buf()
                assert.equal(file_path, vim.api.nvim_buf_get_name(current_buf))
                assert.is_not.equal(
                    widget.win_nrs.chat,
                    vim.api.nvim_get_current_win()
                )
            end
        )

        it(
            "warns without crashing when nvim_win_set_buf fails for the target window",
            function()
                widget:show()
                vim.wo[original_winid].winfixbuf = true

                local file_path = create_test_file()
                set_chat_line(file_path)
                focus_chat_from_editor()

                widget:_goto_file_under_cursor()

                assert.is_true(notify_spy.call_count >= 1)
                local last_call = notify_spy.calls[notify_spy.call_count]
                assert.equal(vim.log.levels.WARN, last_call[2])
                assert.equal(
                    widget.win_nrs.chat,
                    vim.api.nvim_get_current_win()
                )
            end
        )

        it(
            "binds gf with a consistent desc on every widget buffer including input",
            function()
                for _, bufnr in pairs(widget.buf_nrs) do
                    local mapping = vim.api.nvim_buf_call(bufnr, function()
                        return vim.fn.maparg("gf", "n", false, true)
                    end)
                    assert.is_false(vim.tbl_isempty(mapping))
                    assert.equal(
                        "Agentic: Go to file under cursor",
                        mapping.desc
                    )
                end
            end
        )
    end)
end)
