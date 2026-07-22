local assert = require("tests.helpers.assert")

local SessionPrewarm = require("agentic.session_prewarm")

describe("agentic.session_prewarm", function()
    describe("can_recreate_prewarmed_session", function()
        local function empty_list()
            return {
                is_empty = function()
                    return true
                end,
            }
        end

        it(
            "uses lightweight message_count when live messages are not retained",
            function()
                local session = {
                    _is_first_message = true,
                    is_generating = false,
                    chat_history = {
                        messages = {},
                        message_count = 1,
                    },
                    file_list = empty_list(),
                    code_selection = empty_list(),
                    diagnostics_list = empty_list(),
                    todo_list = empty_list(),
                }

                assert.is_true(
                    SessionPrewarm._can_recreate_prewarmed_session(
                        session --[[@as agentic.SessionManager]]
                    )
                )
            end
        )

        it("ignores stale live messages without lightweight count", function()
            local session = {
                _is_first_message = true,
                is_generating = false,
                chat_history = {
                    messages = {
                        { role = "assistant", content = "stale" },
                    },
                },
                file_list = empty_list(),
                code_selection = empty_list(),
                diagnostics_list = empty_list(),
                todo_list = empty_list(),
            }

            assert.is_false(
                SessionPrewarm._can_recreate_prewarmed_session(
                    session --[[@as agentic.SessionManager]]
                )
            )
        end)
    end)
end)
