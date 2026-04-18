local assert = require("tests.helpers.assert")

local States = require("agentic.states")

describe("blink.cmp.sources.agentic_commands", function()
    --- @type blink.cmp.AgenticCommandsSource
    local source
    --- @type integer
    local bufnr
    --- @type integer
    local other_bufnr

    before_each(function()
        package.loaded["blink.cmp.types"] = {
            CompletionItemKind = {
                Event = 24,
            },
        }
        package.loaded["blink.cmp.sources.agentic_commands"] = nil

        local Source = require("blink.cmp.sources.agentic_commands")
        source = Source.new({}, {})

        bufnr = vim.api.nvim_create_buf(false, true)
        other_bufnr = vim.api.nvim_create_buf(false, true)
        vim.bo[bufnr].filetype = "AgenticInput"
        vim.bo[other_bufnr].filetype = "AgenticInput"

        States.setSlashCommands(bufnr, {})
        States.setSlashCommands(other_bufnr, {})
    end)

    after_each(function()
        States.setSlashCommands(bufnr, {})
        States.setSlashCommands(other_bufnr, {})
        package.loaded["blink.cmp.sources.agentic_commands"] = nil
        package.loaded["blink.cmp.types"] = nil

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        if other_bufnr and vim.api.nvim_buf_is_valid(other_bufnr) then
            vim.api.nvim_buf_delete(other_bufnr, { force = true })
        end
    end)

    describe("get_completions", function()
        it(
            "streams buffer-local slash command updates without duplicates",
            function()
                --- @type blink.cmp.AgenticCommands.Context
                local context = {
                    bufnr = bufnr,
                    cursor = { 1, 1 },
                    line = "/",
                }

                --- @type blink.cmp.AgenticCommands.CompletionResponse[]
                local responses = {}
                local cancel = source:get_completions(
                    context,
                    function(response)
                        table.insert(responses, response)
                    end
                )

                assert.equal(1, #responses)
                local initial_response = assert.not_nil(responses[1])
                assert.equal(0, #initial_response.items)
                assert.is_true(initial_response.is_incomplete_forward)
                assert.is_true(initial_response.is_incomplete_backward)

                States.setSlashCommands(bufnr, {
                    {
                        word = "plan",
                        menu = "Create a plan",
                        info = "Create a plan",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "review",
                        menu = "Review code",
                        info = "Review code",
                        kind = "/",
                        icase = 1,
                    },
                })

                assert.equal(2, #responses)
                local second_response = assert.not_nil(responses[2])
                assert.equal(2, #second_response.items)
                local first_item = assert.not_nil(second_response.items[1])
                local second_item = assert.not_nil(second_response.items[2])
                assert.equal("/plan", first_item.label)
                assert.equal("/review", second_item.label)

                States.setSlashCommands(other_bufnr, {
                    {
                        word = "other",
                        menu = "Other buffer",
                        info = "Other buffer",
                        kind = "/",
                        icase = 1,
                    },
                })

                assert.equal(2, #responses)

                States.setSlashCommands(bufnr, {
                    {
                        word = "plan",
                        menu = "Create a plan",
                        info = "Create a plan",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "review",
                        menu = "Review code",
                        info = "Review code",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "new",
                        menu = "Start a new session",
                        info = "Start a new session",
                        kind = "/",
                        icase = 1,
                    },
                })

                assert.equal(3, #responses)
                local third_response = assert.not_nil(responses[3])
                assert.equal(1, #third_response.items)
                local third_item = assert.not_nil(third_response.items[1])
                assert.equal("/new", third_item.label)

                local cancel_fn = assert.not_nil(cancel)
                cancel_fn()

                States.setSlashCommands(bufnr, {
                    {
                        word = "plan",
                        menu = "Create a plan",
                        info = "Create a plan",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "review",
                        menu = "Review code",
                        info = "Review code",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "new",
                        menu = "Start a new session",
                        info = "Start a new session",
                        kind = "/",
                        icase = 1,
                    },
                    {
                        word = "focus",
                        menu = "Focus prompt",
                        info = "Focus prompt",
                        kind = "/",
                        icase = 1,
                    },
                })

                assert.equal(3, #responses)
            end
        )
    end)
end)
