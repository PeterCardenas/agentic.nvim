local assert = require("tests.helpers.assert")

-- These tests exist to force LuaLS type checking and Selene linting on
-- PartialUserConfig usage. They are NOT testing runtime config behavior --
-- they validate that the (partial) type annotations allow incomplete
-- nested tables without triggering type errors or lint warnings.
describe("config_default", function()
    describe("agentic.PartialUserConfig type", function()
        it("accepts a partial top-level config without warnings", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                debug = true,
                provider = "claude-agent-acp",
            }

            assert.equal(true, cfg.debug)
            assert.equal("claude-agent-acp", cfg.provider)
        end)

        it("accepts partial nested windows config", function()
            --- @type agentic.PartialUserConfig.Windows
            local windows = {
                width = "50%",
                position = "left",
            }

            --- @type agentic.PartialUserConfig
            local cfg = {
                windows = windows,
            }

            local resolved_windows = assert.not_nil(cfg.windows)
            assert.equal("50%", resolved_windows.width)
            assert.equal("left", resolved_windows.position)
        end)

        it("accepts partial nested sub-window config", function()
            --- @type agentic.PartialUserConfig.Windows
            local windows = {
                input = { win_opts = { wrap = false } },
                todos = { display = false },
            }

            --- @type agentic.PartialUserConfig
            local cfg = {
                windows = windows,
            }

            local resolved_windows = assert.not_nil(cfg.windows)
            local input = assert.not_nil(resolved_windows.input)
            local todos = assert.not_nil(resolved_windows.todos)
            assert.equal(false, input.win_opts.wrap)
            assert.equal(false, todos.display)
        end)

        it("accepts partial icon overrides", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                status_icons = { pending = "?" },
                chat_icons = { user = "U" },
            }

            local status_icons = assert.not_nil(cfg.status_icons)
            local chat_icons = assert.not_nil(cfg.chat_icons)
            assert.equal("?", status_icons.pending)
            assert.equal("U", chat_icons.user)
        end)

        it("accepts partial keymaps", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                keymaps = {
                    widget = { close = "x" },
                },
            }

            local keymaps = assert.not_nil(cfg.keymaps)
            local widget = assert.not_nil(keymaps.widget)
            assert.equal("x", widget.close)
        end)

        it("accepts partial diff_preview", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                diff_preview = { enabled = false },
            }

            local diff_preview = assert.not_nil(cfg.diff_preview)
            assert.equal(false, diff_preview.enabled)
        end)

        it("accepts partial settings", function()
            --- @type agentic.PartialUserConfig
            local cfg = {
                settings = { move_cursor_to_chat_on_submit = false },
            }

            local settings = assert.not_nil(cfg.settings)
            assert.equal(false, settings.move_cursor_to_chat_on_submit)
        end)

        it("accepts an empty config", function()
            --- @type agentic.PartialUserConfig
            local cfg = {}

            assert.is_table(cfg)
        end)
    end)
end)
