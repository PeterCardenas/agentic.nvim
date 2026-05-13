local assert = require("tests.helpers.assert")
local Theme = require("agentic.theme")

describe("agentic.theme", function()
    describe("setup", function()
        it(
            "defines neutral body highlights for thought and tool call text",
            function()
                vim.api.nvim_set_hl(0, Theme.HL_GROUPS.THOUGHT_TEXT, {})
                vim.api.nvim_set_hl(0, Theme.HL_GROUPS.TOOL_CALL_TEXT, {})

                Theme.setup()

                local normal_hl = vim.api.nvim_get_hl(0, {
                    name = "Normal",
                    link = false,
                })
                local thought_hl = vim.api.nvim_get_hl(0, {
                    name = Theme.HL_GROUPS.THOUGHT_TEXT,
                    link = false,
                })
                local tool_call_hl = vim.api.nvim_get_hl(0, {
                    name = Theme.HL_GROUPS.TOOL_CALL_TEXT,
                    link = false,
                })

                assert.is_true(thought_hl.nocombine)
                assert.is_true(tool_call_hl.nocombine)

                assert.equal(normal_hl.bg, thought_hl.bg)
                assert.equal(normal_hl.bg, tool_call_hl.bg)

                assert.is_falsy(thought_hl.bold)
                assert.is_falsy(tool_call_hl.bold)
                assert.is_falsy(thought_hl.italic)
                assert.is_falsy(tool_call_hl.italic)
                assert.is_falsy(thought_hl.strikethrough)
                assert.is_falsy(tool_call_hl.strikethrough)
                assert.is_falsy(thought_hl.reverse)
                assert.is_falsy(tool_call_hl.reverse)
                assert.is_falsy(thought_hl.underline)
                assert.is_falsy(tool_call_hl.underline)
                assert.is_falsy(thought_hl.undercurl)
                assert.is_falsy(tool_call_hl.undercurl)
            end
        )
    end)
end)
