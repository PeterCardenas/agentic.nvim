local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")
local WidgetLayout = require("agentic.ui.widget_layout")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

describe("WidgetLayout", function()
    --- @type TestStub
    local notify_stub

    before_each(function()
        notify_stub = spy.stub(Logger, "notify")
    end)

    after_each(function()
        notify_stub:revert()
    end)

    describe("calculate_width", function()
        --- @type integer
        local cols
        local default_width_pct =
            assert.not_nil(tonumber(string.sub(Config.windows.width, 1, -2)))

        before_each(function()
            cols = vim.o.columns
        end)

        it("should handle percentage strings", function()
            local width = WidgetLayout.calculate_width(Config.windows.width)
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
        end)

        it("should handle decimal values", function()
            local width = WidgetLayout.calculate_width(0.3)
            assert.are.equal(math.floor(cols * 0.3), width)
        end)

        it("should handle absolute numbers", function()
            local width = WidgetLayout.calculate_width(80)
            assert.are.equal(80, width)
        end)

        it("should default for invalid values", function()
            local width = WidgetLayout.calculate_width("invalid")
            assert.are.equal(math.floor(cols * default_width_pct / 100), width)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local width = WidgetLayout.calculate_width(0.01)
            assert.are.equal(math.max(1, math.floor(cols * 0.01)), width)
        end)
    end)

    describe("calculate_height", function()
        --- @type integer
        local lines
        local default_height_pct =
            assert.not_nil(tonumber(string.sub(Config.windows.height, 1, -2)))

        before_each(function()
            lines = vim.o.lines
        end)

        it("should handle percentage strings", function()
            local height = WidgetLayout.calculate_height(Config.windows.height)
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
        end)

        it("should handle decimal values", function()
            local height = WidgetLayout.calculate_height(0.4)
            assert.are.equal(math.floor(lines * 0.4), height)
        end)

        it("should handle absolute numbers", function()
            local height = WidgetLayout.calculate_height(25)
            assert.are.equal(25, height)
        end)

        it("should default for invalid values", function()
            local height = WidgetLayout.calculate_height("invalid")
            assert.are.equal(
                math.floor(lines * default_height_pct / 100),
                height
            )
            assert.equal(1, notify_stub.call_count)
        end)

        it("should return at least 1", function()
            local height = WidgetLayout.calculate_height(0.01)
            assert.are.equal(math.max(1, math.floor(lines * 0.01)), height)
        end)
    end)

    describe("calculate_input_max_height", function()
        it("caps prompt height at sixty percent of Vim height", function()
            local max_height = WidgetLayout.calculate_input_max_height(3)
            local expected = math.max(3, math.floor(vim.o.lines * 0.6))

            assert.are.equal(expected, max_height)
        end)

        it("does not return less than the minimum height", function()
            local max_height = WidgetLayout.calculate_input_max_height(999)

            assert.are.equal(999, max_height)
        end)
    end)

    describe("close", function()
        it("should close all valid windows", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
            })

            local win_nrs = { chat = winid }
            WidgetLayout.close(win_nrs)

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.chat)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { chat = 99999 }
            WidgetLayout.close(win_nrs)
            assert.is_nil(win_nrs.chat)
        end)

        it("should clear all entries from win_nrs table", function()
            local bufnr1 = vim.api.nvim_create_buf(false, true)
            local bufnr2 = vim.api.nvim_create_buf(false, true)
            local winid1 = vim.api.nvim_open_win(bufnr1, false, {
                split = "right",
                win = -1,
            })
            local winid2 = vim.api.nvim_open_win(bufnr2, false, {
                split = "below",
                win = winid1,
            })

            local win_nrs = { chat = winid1, input = winid2 }
            WidgetLayout.close(win_nrs)

            assert.is_nil(win_nrs.chat)
            assert.is_nil(win_nrs.input)
        end)
    end)

    describe("close_optional_window", function()
        it("should close valid window", function()
            local bufnr = vim.api.nvim_create_buf(false, true)
            local winid = vim.api.nvim_open_win(bufnr, false, {
                split = "right",
                win = -1,
            })

            local win_nrs = { code = winid }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")

            assert.is_false(vim.api.nvim_win_is_valid(winid))
            assert.is_nil(win_nrs.code)
        end)

        it("should handle invalid windows gracefully", function()
            local win_nrs = { code = 99999 }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")
            assert.is_nil(win_nrs.code)
        end)

        it("should handle nil windows", function()
            local win_nrs = { code = nil }
            WidgetLayout.close_optional_window(win_nrs, "code", "right")
            assert.is_nil(win_nrs.code)
        end)

        it("should restore chat height in bottom layout", function()
            local chat_buf = vim.api.nvim_create_buf(false, true)
            local code_buf = vim.api.nvim_create_buf(false, true)

            local chat_winid = vim.api.nvim_open_win(chat_buf, false, {
                split = "below",
                win = -1,
                height = 20,
            })
            local code_winid = vim.api.nvim_open_win(code_buf, false, {
                split = "below",
                win = chat_winid,
                height = 5,
            })

            local before_height = vim.api.nvim_win_get_height(chat_winid)

            local win_nrs = { chat = chat_winid, code = code_winid }
            WidgetLayout.close_optional_window(win_nrs, "code", "bottom")

            assert.equal(before_height, vim.api.nvim_win_get_height(chat_winid))

            pcall(vim.api.nvim_win_close, chat_winid, true)
        end)
    end)

    describe("open", function()
        it("should not error with invalid tabpage", function()
            assert.has_no_errors(function()
                WidgetLayout.open({
                    tab_page_id = 99999,
                    buf_nrs = {},
                    win_nrs = {},
                    position = "right",
                })
            end)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should not error with nil tabpage", function()
            assert.has_no_errors(function()
                WidgetLayout.open({
                    ---@diagnostic disable-next-line: assign-type-mismatch
                    tab_page_id = nil,
                    buf_nrs = {},
                    win_nrs = {},
                    position = "right",
                })
            end)
            assert.equal(1, notify_stub.call_count)
        end)

        it("should fall back to right for invalid position", function()
            vim.cmd("tabnew")
            local tab_page_id = vim.api.nvim_get_current_tabpage()

            local win_nrs = {}
            local buf_nrs = {
                chat = vim.api.nvim_create_buf(false, true),
                input = vim.api.nvim_create_buf(false, true),
                code = vim.api.nvim_create_buf(false, true),
                files = vim.api.nvim_create_buf(false, true),
                diagnostics = vim.api.nvim_create_buf(false, true),
                todos = vim.api.nvim_create_buf(false, true),
            }

            assert.has_no_errors(function()
                WidgetLayout.open({
                    tab_page_id = tab_page_id,
                    buf_nrs = buf_nrs,
                    win_nrs = win_nrs,
                    --- @diagnostic disable-next-line: assign-type-mismatch
                    position = "invalid",
                })
            end)

            -- Should have created windows via "right" fallback
            assert.is_not_nil(win_nrs.chat)
            assert.is_not_nil(win_nrs.input)
            -- Should have notified about invalid position
            assert.equal(1, notify_stub.call_count)

            WidgetLayout.close(win_nrs)
            pcall(function()
                vim.cmd("tabclose")
            end)
        end)
    end)
end)
