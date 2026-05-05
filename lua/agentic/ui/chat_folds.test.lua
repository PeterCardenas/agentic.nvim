--- @diagnostic disable: invisible
local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local ExtmarkBlock = require("agentic.utils.extmark_block")

local NS_TOOL_BLOCKS = vim.api.nvim_create_namespace("agentic_tool_blocks")

--- Helper to create a chat buffer with tool call block content
--- @param line_count integer Number of body lines
--- @return integer bufnr
--- @return integer winid
--- @return table<string, agentic.ui.MessageWriter.ToolCallBlock> tool_call_blocks
--- @return string tool_call_id
local function create_tool_call_buffer(line_count)
    local bufnr = vim.api.nvim_create_buf(false, true)
    local winid = vim.api.nvim_open_win(bufnr, true, {
        relative = "editor",
        width = 80,
        height = 40,
        row = 0,
        col = 0,
    })

    -- Build lines: header + body + footer
    local lines = { " execute(ls) " }
    for i = 1, line_count do
        table.insert(lines, "output line " .. i)
    end
    table.insert(lines, "") -- footer

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)

    local header_row = 0
    local footer_row = #lines - 1

    -- Create range extmark spanning the block
    local extmark_id =
        vim.api.nvim_buf_set_extmark(bufnr, NS_TOOL_BLOCKS, header_row, 0, {
            end_row = footer_row,
            right_gravity = false,
        })

    local tool_call_id = "tc_1"

    --- @type table<string, agentic.ui.MessageWriter.ToolCallBlock>
    local tool_call_blocks = {
        [tool_call_id] = {
            tool_call_id = tool_call_id,
            kind = "execute",
            argument = "ls",
            status = "completed",
            body = {},
            extmark_id = extmark_id,
            fold_text_prefix = ExtmarkBlock.BODY_PREFIX,
        },
    }

    return bufnr, winid, tool_call_blocks, tool_call_id
end

describe("agentic.ui.ChatFolds", function()
    --- @type agentic.ui.ChatFolds
    local ChatFolds

    --- @type table
    local original_folding

    before_each(function()
        ChatFolds = require("agentic.ui.chat_folds")
        original_folding = Config.folding
    end)

    after_each(function()
        Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch
    end)

    --- Set up folding config for testing
    --- @param overrides table|nil
    local function setup_config(overrides)
        --- @type agentic.UserConfig.Folding
        local folding = {
            tool_calls = {
                enabled = true,
                closed_by_default = false,
                preview = true,
                min_lines = 5,
                kinds = {},
            },
        }

        if overrides then
            folding = vim.tbl_deep_extend("force", folding, overrides) --[[@as agentic.UserConfig.Folding]]
        end

        Config.folding = folding --- @diagnostic disable-line: assign-type-mismatch
    end

    describe("_resolve_policy", function()
        it("returns disabled when no folding config", function()
            Config.folding = nil --- @diagnostic disable-line: assign-type-mismatch
            local enabled, min_lines, closed =
                ChatFolds._resolve_policy("execute")
            assert.is_false(enabled)
            assert.equal(20, min_lines)
            assert.is_false(closed)
        end)

        it("returns disabled when folding is off", function()
            setup_config({ tool_calls = { enabled = false } })
            local enabled = ChatFolds._resolve_policy("execute")
            assert.is_false(enabled)
        end)

        it("uses global defaults when kind has no override", function()
            setup_config()
            local enabled, min_lines, closed =
                ChatFolds._resolve_policy("unknown_kind")
            assert.is_true(enabled)
            assert.equal(5, min_lines)
            assert.is_false(closed)
        end)

        it("uses per-kind min_lines override", function()
            setup_config({
                tool_calls = {
                    kinds = { fetch = { min_lines = 3 } },
                },
            })
            local enabled, min_lines = ChatFolds._resolve_policy("fetch")
            assert.is_true(enabled)
            assert.equal(3, min_lines)
        end)

        it("uses per-kind closed_by_default override", function()
            setup_config({
                tool_calls = {
                    kinds = {
                        execute = { closed_by_default = true },
                    },
                },
            })
            local _, _, closed = ChatFolds._resolve_policy("execute")
            assert.is_true(closed)
        end)

        it("defaults preview to true", function()
            setup_config()
            local _, _, _, preview = ChatFolds._resolve_policy("execute")
            assert.is_true(preview)
        end)

        it("returns global preview=false", function()
            setup_config({ tool_calls = { preview = false } })
            local _, _, _, preview = ChatFolds._resolve_policy("execute")
            assert.is_false(preview)
        end)

        it("uses per-kind preview override", function()
            setup_config({
                tool_calls = {
                    kinds = { read = { preview = false } },
                },
            })
            local _, _, _, preview = ChatFolds._resolve_policy("read")
            assert.is_false(preview)

            -- Other kinds still use global default
            local _, _, _, preview2 = ChatFolds._resolve_policy("execute")
            assert.is_true(preview2)
        end)
    end)

    describe("_resolve_body_range", function()
        it("returns nil when tracker not found", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local s, e, bs =
                ChatFolds._resolve_body_range(bufnr, {}, "nonexistent")
            assert.is_nil(s)
            assert.is_nil(e)
            assert.is_nil(bs)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("returns body range from extmark", function()
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)

            local body_start, body_end, block_start =
                ChatFolds._resolve_body_range(bufnr, blocks, tc_id)

            -- header=0, body starts at 1-indexed line 2, footer at line 12
            assert.equal(2, body_start)
            assert.equal(11, body_end)
            assert.equal(0, block_start)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("reset", function()
        it("clears all tracked state", function()
            setup_config()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds._tool_call_folds["tc_1"] = {
                tool_call_id = "tc_1",
                should_render_fold = true,
            }

            folds:reset()

            assert.same({}, folds._tool_call_folds)

            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("_get_visible_windows", function()
        it("returns only windows in the owning tabpage", function()
            setup_config()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local tab1 = vim.api.nvim_get_current_tabpage()

            local win1 = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 40,
                height = 10,
                row = 0,
                col = 0,
            })

            local folds = ChatFolds:new(bufnr, tab1)
            local wins = folds:_get_visible_windows()

            assert.equal(1, #wins)
            assert.equal(win1, wins[1])

            vim.api.nvim_win_close(win1, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("sync_tool_call", function()
        it("does not fold when body is below threshold", function()
            setup_config({ tool_calls = { min_lines = 50 } })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.is_false(fold.should_render_fold)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("creates a fold when body exceeds threshold", function()
            setup_config({ tool_calls = { min_lines = 5 } })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.is_true(fold.should_render_fold)

            -- Check fold exists in the window
            local fold_state = ChatFolds._get_fold_state(winid, 2) -- body_start
            -- Fold should exist (either open or closed)
            assert.is_not_nil(fold_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("does not fold in-progress tool calls", function()
            setup_config({ tool_calls = { min_lines = 5 } })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            blocks[tc_id].status = "pending"
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.is_false(fold.should_render_fold)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it(
            "removes an existing fold when the tool call becomes in progress",
            function()
                setup_config({ tool_calls = { min_lines = 5 } })
                local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
                local tab = vim.api.nvim_get_current_tabpage()

                local folds = ChatFolds:new(bufnr, tab)
                folds:sync_tool_call(tc_id, blocks)

                assert.is_not_nil(ChatFolds._get_fold_state(winid, 2))

                blocks[tc_id].status = "in_progress"
                folds:sync_tool_call(tc_id, blocks)

                assert.is_nil(ChatFolds._get_fold_state(winid, 2))

                vim.api.nvim_win_close(winid, true)
                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it(
            "records fold without creating any when no visible windows",
            function()
                setup_config({ tool_calls = { min_lines = 5 } })
                local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
                local tab = vim.api.nvim_get_current_tabpage()

                -- Close window so there are no visible windows
                vim.api.nvim_win_close(winid, true)

                -- Use a different tab_page_id to ensure _get_visible_windows returns empty
                local folds = ChatFolds:new(bufnr, tab + 999)
                folds:sync_tool_call(tc_id, blocks)

                -- Fold metadata is tracked even without a window; the actual
                -- fold is created on reshow by on_buf_win_enter.
                assert.is_not_nil(folds._tool_call_folds[tc_id])
                assert.is_true(folds._tool_call_folds[tc_id].should_render_fold)

                vim.api.nvim_buf_delete(bufnr, { force = true })
            end
        )

        it("creates fold as open by default", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = false },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local state = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(state) -- open

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("creates fold as closed when configured", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = true },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local state = ChatFolds._get_fold_state(winid, 2)
            assert.is_true(state) -- closed

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("nested inner fold", function()
        it("creates inner fold when body exceeds min_lines", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = false },
            })
            -- 10 body lines, min_lines=5 → inner fold at body_start+5 = line 7
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Outer fold at body_start (line 2) should be open
            local outer_state = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(outer_state)

            -- Inner fold at line 7 (2 + 5) should be closed
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_true(inner_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("does not create inner fold when body equals min_lines", function()
            setup_config({
                tool_calls = { min_lines = 10, closed_by_default = false },
            })
            -- 10 body lines, min_lines=10 → inner_start=12 > body_end=11
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Outer fold exists and is open
            local outer_state = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(outer_state)

            -- Line 7 is inside the outer fold (open), no separate inner fold
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_false(inner_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("inner fold closed hides remainder, outer fold hides all", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = false },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Close the outer fold
            ChatFolds._set_fold_state(winid, 2, true)
            local state = ChatFolds._get_fold_state(winid, 2)
            assert.is_true(state) -- everything hidden

            -- Open outer again → inner should still be closed
            ChatFolds._set_fold_state(winid, 2, false)
            local outer_state = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(outer_state)

            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_true(inner_state) -- still closed

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("preview=false starts with both folds open", function()
            setup_config({
                tool_calls = {
                    min_lines = 5,
                    closed_by_default = false,
                    preview = false,
                },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Outer fold open
            local outer_state = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(outer_state)

            -- Inner fold also open (preview disabled)
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_false(inner_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("per-kind preview=false overrides global preview=true", function()
            setup_config({
                tool_calls = {
                    min_lines = 5,
                    closed_by_default = false,
                    preview = true,
                    kinds = { execute = { preview = false } },
                },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Inner fold open because execute kind has preview=false
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_false(inner_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("stores min_lines on tool call fold", function()
            setup_config({
                tool_calls = { min_lines = 5 },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.equal(5, fold.min_lines)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("capture and restore fold state", function()
        it("preserves user toggle across update", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = false },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Fold is open by default. User closes it.
            ChatFolds._set_fold_state(winid, 2, true)
            local state = ChatFolds._get_fold_state(winid, 2)
            assert.is_true(state)

            -- Capture before update
            folds:capture_tool_call_fold_state(tc_id, blocks)

            -- Simulate re-sync (as would happen on update)
            folds:sync_tool_call(tc_id, blocks)

            -- Fold should remain closed because user closed it
            local new_state = ChatFolds._get_fold_state(winid, 2)
            assert.is_true(new_state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("preserves inner fold toggle across update", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = false },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- Inner fold at line 7 is closed by default. User opens it.
            ChatFolds._set_fold_state(winid, 7, false)
            local inner_state = ChatFolds._get_fold_state(winid, 7)
            assert.is_false(inner_state)

            -- Capture before update
            folds:capture_tool_call_fold_state(tc_id, blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.is_false(fold.last_known_fold_state) -- outer open
            assert.is_false(fold.last_known_inner_fold_state) -- inner open

            -- Re-sync
            folds:sync_tool_call(tc_id, blocks)

            -- Both should remain open
            local new_outer = ChatFolds._get_fold_state(winid, 2)
            assert.is_false(new_outer)
            local new_inner = ChatFolds._get_fold_state(winid, 7)
            assert.is_false(new_inner)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("captures visible fold states before hide", function()
            setup_config({
                tool_calls = { min_lines = 5, closed_by_default = true },
            })
            local bufnr, winid, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            folds:sync_tool_call(tc_id, blocks)

            -- User opens the fold
            ChatFolds._set_fold_state(winid, 2, false)

            -- Capture all fold states (as would happen on widget hide)
            folds:capture_visible_fold_states(blocks)

            local fold = folds._tool_call_folds[tc_id]
            assert.is_false(fold.last_known_fold_state) -- user opened it

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("on_buf_win_enter", function()
        it("creates folds for tracked tool calls on reshow", function()
            setup_config({ tool_calls = { min_lines = 5 } })
            local bufnr, _, blocks, tc_id = create_tool_call_buffer(10)
            local tab = vim.api.nvim_get_current_tabpage()

            -- Create folds with no visible window
            local folds = ChatFolds:new(bufnr, tab + 999)
            folds:sync_tool_call(tc_id, blocks)

            assert.is_not_nil(folds._tool_call_folds[tc_id])

            -- Now open a window and call on_buf_win_enter
            local winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 80,
                height = 40,
                row = 0,
                col = 0,
            })

            -- Fix tab_page_id so _get_visible_windows works
            folds._tab_page_id = vim.api.nvim_get_current_tabpage()

            folds:on_buf_win_enter(winid, blocks)

            -- Fold should now exist
            local state = ChatFolds._get_fold_state(winid, 2)
            assert.is_not_nil(state)

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)

        it("skips fold setup when folding is disabled", function()
            setup_config({ tool_calls = { enabled = false } })
            local bufnr = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "line 1" })
            local winid = vim.api.nvim_open_win(bufnr, true, {
                relative = "editor",
                width = 80,
                height = 20,
                row = 0,
                col = 0,
            })
            local tab = vim.api.nvim_get_current_tabpage()

            local folds = ChatFolds:new(bufnr, tab)
            -- Should not error
            folds:on_buf_win_enter(winid, {})

            vim.api.nvim_win_close(winid, true)
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end)
    end)

    describe("foldtext", function()
        it("returns virtual text chunks", function()
            -- foldtext is a static function that reads vim.v.foldstart/foldend
            -- We can't easily mock those, but we can verify it returns a table
            local result = ChatFolds.foldtext()
            assert.is_not_nil(result)
            assert.equal("table", type(result))
        end)
    end)

    describe("_decide_default_states", function()
        it("uses last known state when available", function()
            --- @type agentic.ui.ChatFolds.ToolCallFold
            local fold = {
                tool_call_id = "tc_1",
                default_closed = false,
                last_known_fold_state = true,
                last_known_inner_fold_state = false,
            }
            local outer, inner = ChatFolds._decide_default_states(fold)
            assert.is_true(outer)
            assert.is_false(inner)
        end)

        it("falls back to default_closed when no last known state", function()
            --- @type agentic.ui.ChatFolds.ToolCallFold
            local fold = {
                tool_call_id = "tc_1",
                default_closed = true,
            }
            local outer, inner = ChatFolds._decide_default_states(fold)
            assert.is_true(outer)
            -- Inner defaults to closed (preview mode)
            assert.is_true(inner)
        end)

        it(
            "defaults to open outer and closed inner when nothing set",
            function()
                --- @type agentic.ui.ChatFolds.ToolCallFold
                local fold = {
                    tool_call_id = "tc_1",
                }
                local outer, inner = ChatFolds._decide_default_states(fold)
                assert.is_false(outer)
                assert.is_true(inner)
            end
        )

        it("inner defaults to open when preview is false", function()
            --- @type agentic.ui.ChatFolds.ToolCallFold
            local fold = {
                tool_call_id = "tc_1",
                preview = false,
            }
            local outer, inner = ChatFolds._decide_default_states(fold)
            assert.is_false(outer)
            assert.is_false(inner)
        end)

        it("last_known_inner_fold_state overrides preview=false", function()
            --- @type agentic.ui.ChatFolds.ToolCallFold
            local fold = {
                tool_call_id = "tc_1",
                preview = false,
                last_known_inner_fold_state = true,
            }
            local _, inner = ChatFolds._decide_default_states(fold)
            assert.is_true(inner)
        end)
    end)
end)
