local TextMatcher = require("agentic.utils.text_matcher")
local assert = require("tests.helpers.assert")

describe("TextMatcher", function()
    describe("find_all_prefix_boundary_matches", function()
        it(
            "should match when last target line is prefix of file line",
            function()
                local file_lines = {
                    "  vi.mocked(generateText).mockResolvedValue(mockResult('corporate text'));",
                    "",
                    "  const { executeWithPool } = await import('./pool.ts');",
                    "  const result = await executeWithPool(pool, { input: 'test' }, 'system');",
                }

                local target_lines = {
                    "  vi.mocked(generateText).mockResolvedValue(mockResult('corporate text'));",
                    "",
                    "  const { executeWithPool } = await import('./pool.ts');",
                    "  const result",
                }

                local matches = TextMatcher.find_all_prefix_boundary_matches(
                    file_lines,
                    target_lines
                )

                assert.equal(1, #matches)
                local first_match = assert.not_nil(matches[1])
                assert.equal(1, first_match.start_line)
                assert.equal(4, first_match.end_line)
                assert.equal(
                    " = await executeWithPool(pool, { input: 'test' }, 'system');",
                    first_match.suffix
                )
            end
        )

        it("should return empty for single-line target", function()
            local file_lines = { "const result = 1;" }
            local target_lines = { "const result" }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)

        it("should return empty when no prefix match on last line", function()
            local file_lines = {
                "line one",
                "line two",
                "line three completely different",
            }

            local target_lines = {
                "line one",
                "line two",
                "no match here",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)

        it("should find multiple prefix matches", function()
            local file_lines = {
                "function a()",
                "  return 1 + extra",
                "end",
                "function a()",
                "  return 1 + extra",
                "end",
            }

            local target_lines = {
                "function a()",
                "  return 1",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(2, #matches)
            local first_match = assert.not_nil(matches[1])
            local second_match = assert.not_nil(matches[2])
            assert.equal(1, first_match.start_line)
            assert.equal(" + extra", first_match.suffix)
            assert.equal(4, second_match.start_line)
            assert.equal(" + extra", second_match.suffix)
        end)

        it(
            "should match with whitespace-trimmed strategy when exact fails",
            function()
                local file_lines = {
                    "line one  ",
                    "line two = full content;",
                }

                local target_lines = {
                    "line one",
                    "line two",
                }

                local matches = TextMatcher.find_all_prefix_boundary_matches(
                    file_lines,
                    target_lines
                )

                assert.equal(1, #matches)
                local first_match = assert.not_nil(matches[1])
                assert.equal(" = full content;", first_match.suffix)
            end
        )

        it("should not match when head lines differ", function()
            local file_lines = {
                "different line",
                "const result = await foo();",
            }

            local target_lines = {
                "line one",
                "const result",
            }

            local matches = TextMatcher.find_all_prefix_boundary_matches(
                file_lines,
                target_lines
            )

            assert.equal(0, #matches)
        end)
    end)
end)
