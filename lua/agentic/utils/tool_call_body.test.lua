local assert = require("tests.helpers.assert")
local Config = require("agentic.config")
local ToolCallBody = require("agentic.utils.tool_call_body")

describe("agentic.utils.ToolCallBody", function()
    local original_folding

    before_each(function()
        original_folding = Config.folding
    end)

    after_each(function()
        Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch
    end)

    describe("truncate_for_display", function()
        it("returns body unchanged when under limit", function()
            local body = { "a", "b" }
            local display, truncated =
                ToolCallBody.truncate_for_display(body, 5)
            assert.is_false(truncated)
            assert.same(body, display)
        end)

        it("truncates with footer when over limit", function()
            local body = { "1", "2", "3", "4" }
            local display, truncated =
                ToolCallBody.truncate_for_display(body, 2)
            assert.is_true(truncated)
            assert.equal(3, #display)
            assert.equal("1", display[1])
            assert.equal("2", display[2])
            local footer = assert.not_nil(display[3])
            assert.truthy(footer:match("2 more lines omitted"))
        end)

        it("does not truncate when max_lines is nil", function()
            local body = { "1", "2", "3" }
            local display, truncated =
                ToolCallBody.truncate_for_display(body, nil)
            assert.is_false(truncated)
            assert.same(body, display)
        end)
    end)

    describe("get_max_display_lines", function()
        it("uses config value when set", function()
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    closed_by_default = false,
                    preview = true,
                    min_lines = 20,
                    max_display_lines = 42,
                },
            } --- @diagnostic disable-line: assign-type-mismatch
            assert.equal(42, ToolCallBody.get_max_display_lines())
        end)
    end)
end)
