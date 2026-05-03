local assert = require("tests.helpers.assert")

local States = require("agentic.states")

local function wait_for_insert_mode()
    local entered_insert = vim.wait(100, function()
        return vim.api.nvim_get_mode().mode:sub(1, 1) == "i"
    end, 10)
    assert.is_true(entered_insert)
end

local function wait_for_normal_mode()
    local entered_normal = vim.wait(100, function()
        return vim.api.nvim_get_mode().mode == "n"
    end, 10)
    assert.is_true(entered_normal)
end

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
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.ui.file_picker"] = nil

        if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
            vim.api.nvim_buf_delete(bufnr, { force = true })
        end
        if other_bufnr and vim.api.nvim_buf_is_valid(other_bufnr) then
            vim.api.nvim_buf_delete(other_bufnr, { force = true })
        end
    end)

    describe("get_completions", function()
        it("returns file picker completion for @ context", function()
            --- @type blink.cmp.AgenticCommands.Context
            local context = {
                bufnr = bufnr,
                cursor = { 1, 5 },
                line = "foo @",
            }

            --- @type blink.cmp.AgenticCommands.CompletionResponse[]
            local responses = {}
            local cancel = source:get_completions(context, function(response)
                table.insert(responses, response)
            end)

            assert.is_nil(cancel)
            assert.equal(1, #responses)
            local response = assert.not_nil(responses[1])
            assert.equal(1, #response.items)
            local item = assert.not_nil(response.items[1])
            assert.equal("file", item.label)
            assert.equal("file", item.insertText)
            local text_edit = assert.not_nil(item.textEdit)
            assert.equal("", text_edit.newText)
        end)

        it(
            "streams buffer-local slash command updates without duplicates",
            function()
                vim.api.nvim_set_current_buf(bufnr)
                vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })
                vim.api.nvim_win_set_cursor(0, { 1, 1 })
                vim.cmd("startinsert")
                wait_for_insert_mode()

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

        it("uses the current prompt context for streamed updates", function()
            vim.api.nvim_set_current_buf(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })
            vim.cmd("startinsert")
            wait_for_insert_mode()

            --- @type blink.cmp.AgenticCommands.Context
            local context = {
                bufnr = bufnr,
                cursor = { 1, 1 },
                line = "/",
            }

            --- @type blink.cmp.AgenticCommands.CompletionResponse[]
            local responses = {}
            local cancel = source:get_completions(context, function(response)
                table.insert(responses, response)
            end)

            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/re" })
            vim.api.nvim_win_set_cursor(0, { 1, 3 })

            States.setSlashCommands(bufnr, {
                {
                    word = "review",
                    menu = "Review code",
                    info = "Review code",
                    kind = "/",
                    icase = 1,
                },
            })

            assert.equal(2, #responses)
            local update_response = assert.not_nil(responses[2])
            local update_item = assert.not_nil(update_response.items[1])
            local text_edit = assert.not_nil(update_item.textEdit)
            assert.equal(3, text_edit.range["end"].character)

            local cancel_fn = assert.not_nil(cancel)
            cancel_fn()
            vim.cmd("stopinsert")
            wait_for_normal_mode()
        end)

        it("stops streaming updates after leaving insert mode", function()
            vim.api.nvim_set_current_buf(bufnr)
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })
            vim.cmd("startinsert")
            wait_for_insert_mode()

            --- @type blink.cmp.AgenticCommands.Context
            local context = {
                bufnr = bufnr,
                cursor = { 1, 1 },
                line = "/",
            }

            --- @type blink.cmp.AgenticCommands.CompletionResponse[]
            local responses = {}
            local cancel = source:get_completions(context, function(response)
                table.insert(responses, response)
            end)

            vim.cmd("stopinsert")
            wait_for_normal_mode()

            States.setSlashCommands(bufnr, {
                {
                    word = "review",
                    menu = "Review code",
                    info = "Review code",
                    kind = "/",
                    icase = 1,
                },
            })

            assert.equal(1, #responses)

            vim.cmd("startinsert")
            wait_for_insert_mode()
            vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "/" })
            vim.api.nvim_win_set_cursor(0, { 1, 1 })

            States.setSlashCommands(bufnr, {
                {
                    word = "review",
                    menu = "Review code",
                    info = "Review code",
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

            assert.equal(1, #responses)

            local cancel_fn = assert.not_nil(cancel)
            cancel_fn()
            vim.cmd("stopinsert")
            wait_for_normal_mode()
        end)
    end)

    describe("should_show_items", function()
        it("shows items for @ completion context", function()
            --- @type blink.cmp.AgenticCommands.Context
            local context = {
                bufnr = bufnr,
                cursor = { 1, 1 },
                line = "@",
            }

            local should_show = source:should_show_items(context, {})
            assert.is_true(should_show)
        end)

        it("does not show items for absolute path subpaths", function()
            --- @type blink.cmp.AgenticCommands.Context
            local context = {
                bufnr = bufnr,
                cursor = { 1, 13 },
                line = "/tmp/project/",
            }

            local should_show = source:should_show_items(context, {})
            assert.is_false(should_show)
        end)
    end)

    describe("get_trigger_characters", function()
        it("triggers completion for slash and at-sign", function()
            local triggers = source:get_trigger_characters()
            assert.equal(2, #triggers)
            assert.equal("/", triggers[1])
            assert.equal("@", triggers[2])
        end)
    end)

    describe("execute", function()
        it(
            "uses blink default accept and opens the session file picker",
            function()
                local file_picker_called = false
                package.loaded["agentic.ui.file_picker"] = {
                    open = function(on_file_selected, on_complete)
                        file_picker_called = type(on_file_selected)
                            == "function"
                        if on_complete then
                            on_complete()
                        end
                    end,
                }
                package.loaded["agentic.session_registry"] = {
                    sessions = {
                        [vim.api.nvim_get_current_tabpage()] = {
                            widget = {
                                focus_prompt = function() end,
                                show = function(_opts) end,
                            },
                            file_list = {
                                add = function(_file_path)
                                    return true
                                end,
                            },
                        },
                    },
                }

                local default_called = false
                local callback_called = false
                source:execute(
                    {
                        bufnr = bufnr,
                        cursor = { 1, 8 },
                        line = "before @ after",
                    },
                    { data = { action = "agentic_open_file_picker" } },
                    function()
                        callback_called = true
                    end,
                    function()
                        default_called = true
                    end
                )

                assert.is_true(file_picker_called)
                assert.is_true(callback_called)
                assert.is_true(default_called)
                package.loaded["agentic.session_registry"] = nil
            end
        )
    end)
end)
