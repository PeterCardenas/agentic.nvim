local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("agentic", function()
    describe("new_session", function()
        --- @type agentic.Agentic|nil
        local Agentic
        --- @type table<string, any>|nil
        local config_mock
        --- @type table<string, any>|nil
        local session_registry_mock
        --- @type TestStub|nil
        local get_reusable_session_stub
        --- @type table<string, any>
        local original_loaded = {}

        before_each(function()
            config_mock = {
                provider = "claude-acp",
                acp_providers = {
                    ["claude-acp"] = {},
                    ["gemini-acp"] = {},
                },
            }

            session_registry_mock = {
                sessions = {},
                get_session_for_tab_page = function() end,
                get_reusable_session = function() end,
                new_session = spy.new(function() end),
            }

            original_loaded = {
                ["agentic"] = package.loaded["agentic"],
                ["agentic.config"] = package.loaded["agentic.config"],
                ["agentic.acp.agent_instance"] = package.loaded["agentic.acp.agent_instance"],
                ["agentic.theme"] = package.loaded["agentic.theme"],
                ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
                ["agentic.session_restore"] = package.loaded["agentic.session_restore"],
                ["agentic.utils.object"] = package.loaded["agentic.utils.object"],
                ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
            }

            package.loaded["agentic"] = nil
            package.loaded["agentic.config"] = config_mock
            package.loaded["agentic.acp.agent_instance"] = {
                cleanup_all = function() end,
            }
            package.loaded["agentic.theme"] = {
                setup = function() end,
            }
            package.loaded["agentic.session_registry"] = session_registry_mock
            package.loaded["agentic.session_restore"] = {}
            package.loaded["agentic.utils.object"] = {
                merge_config = function() end,
            }
            package.loaded["agentic.utils.logger"] = {
                notify = function() end,
            }

            Agentic = require("agentic")

            local session_registry = assert.not_nil(session_registry_mock)
            get_reusable_session_stub =
                spy.stub(session_registry, "get_reusable_session")
        end)

        after_each(function()
            for key, value in pairs(original_loaded) do
                package.loaded[key] = value
            end
        end)

        it(
            "reuses the existing session when new_session should be reused",
            function()
                local session_registry = assert.not_nil(session_registry_mock)
                local reusable_session_stub =
                    assert.not_nil(get_reusable_session_stub)
                local agentic = assert.not_nil(Agentic)
                local add_context_spy = spy.new(function() end)
                local show_spy = spy.new(function() end)
                local clear_maximize_state_spy = spy.new(function() end)
                local current_tab_id = vim.api.nvim_get_current_tabpage()
                local old_session = {
                    add_selection_or_file_to_session = add_context_spy,
                    widget = {
                        _clear_maximize_state = clear_maximize_state_spy,
                        is_open = function()
                            return false
                        end,
                        tab_page_id = current_tab_id,
                        show = show_spy,
                    },
                }
                session_registry.sessions[current_tab_id] = old_session
                reusable_session_stub:returns(old_session)

                agentic.new_session()

                assert.spy(session_registry.new_session).was.called(0)
                assert.spy(clear_maximize_state_spy).was.called(1)
                assert.spy(add_context_spy).was.called(1)
                assert.spy(show_spy).was.called(1)
            end
        )

        it("skips auto context when reuse opts disable it", function()
            local session_registry = assert.not_nil(session_registry_mock)
            local reusable_session_stub =
                assert.not_nil(get_reusable_session_stub)
            local agentic = assert.not_nil(Agentic)
            local add_context_spy = spy.new(function() end)
            local show_spy = spy.new(function() end)
            local clear_maximize_state_spy = spy.new(function() end)
            local current_tab_id = vim.api.nvim_get_current_tabpage()
            local old_session = {
                add_selection_or_file_to_session = add_context_spy,
                widget = {
                    _clear_maximize_state = clear_maximize_state_spy,
                    is_open = function()
                        return false
                    end,
                    tab_page_id = current_tab_id,
                    show = show_spy,
                },
            }
            session_registry.sessions[current_tab_id] = old_session
            reusable_session_stub:returns(old_session)

            agentic.new_session({
                auto_add_to_context = false,
            })

            assert.spy(session_registry.new_session).was.called(0)
            assert.spy(clear_maximize_state_spy).was.called(1)
            assert.spy(add_context_spy).was.called(0)
            assert.spy(show_spy).was.called(1)
        end)
    end)

    describe("setup", function()
        --- @type agentic.Agentic|nil
        local Agentic
        --- @type table<string, any>|nil
        local config_mock
        --- @type table<string, any>
        local original_loaded = {}
        --- @type TestSpy|nil
        local keymap_set_spy
        --- @type TestStub|nil
        local new_signal_stub

        before_each(function()
            config_mock = {
                provider = "claude-acp",
                acp_providers = {
                    ["claude-acp"] = {},
                    ["gemini-acp"] = {},
                },
                image_paste = { enabled = false },
                keymaps = {
                    widget = {
                        toggle_prompt_code = "<leader>af",
                        switch_model_global = "<leader>am",
                        switch_config_option_global = "<leader>ao",
                        switch_provider_global = "<leader>ax",
                    },
                },
            }

            original_loaded = {
                ["agentic"] = package.loaded["agentic"],
                ["agentic.config"] = package.loaded["agentic.config"],
                ["agentic.acp.agent_instance"] = package.loaded["agentic.acp.agent_instance"],
                ["agentic.theme"] = package.loaded["agentic.theme"],
                ["agentic.session_registry"] = package.loaded["agentic.session_registry"],
                ["agentic.session_restore"] = package.loaded["agentic.session_restore"],
                ["agentic.session_prewarm"] = package.loaded["agentic.session_prewarm"],
                ["agentic.utils.object"] = package.loaded["agentic.utils.object"],
                ["agentic.utils.logger"] = package.loaded["agentic.utils.logger"],
            }

            package.loaded["agentic"] = nil
            package.loaded["agentic.config"] = config_mock
            package.loaded["agentic.acp.agent_instance"] = {
                cleanup_all = function() end,
            }
            package.loaded["agentic.theme"] = {
                setup = function() end,
            }
            package.loaded["agentic.session_registry"] = {
                sessions = {},
                get_session_for_tab_page = function() end,
            }
            package.loaded["agentic.session_restore"] = {}
            package.loaded["agentic.session_prewarm"] = {
                setup = function() end,
            }
            package.loaded["agentic.utils.object"] = {
                merge_config = function() end,
            }
            package.loaded["agentic.utils.logger"] = {
                notify = function() end,
            }

            keymap_set_spy = spy.on(vim.keymap, "set")
            new_signal_stub = spy.stub(vim.uv, "new_signal")
            new_signal_stub:returns(nil)

            Agentic = require("agentic")
        end)

        after_each(function()
            local resolved_keymap_set_spy = keymap_set_spy
            if resolved_keymap_set_spy then
                resolved_keymap_set_spy:revert()
            end

            local resolved_new_signal_stub = new_signal_stub
            if resolved_new_signal_stub then
                resolved_new_signal_stub:revert()
            end

            for key, value in pairs(original_loaded) do
                package.loaded[key] = value
            end
        end)

        it("registers the global provider switch keymap", function()
            local agentic = assert.not_nil(Agentic)
            local resolved_keymap_set_spy = assert.not_nil(keymap_set_spy)

            agentic.setup({})

            local provider_call
            for _, call in ipairs(resolved_keymap_set_spy.calls) do
                if call[2] == "<leader>ax" then
                    provider_call = call
                    break
                end
            end

            local resolved_provider_call = assert.not_nil(provider_call)
            assert.equal("n", resolved_provider_call[1])
            assert.equal("<leader>ax", resolved_provider_call[2])
            assert.equal(agentic.switch_provider, resolved_provider_call[3])
            assert.equal(
                "Agentic: Switch provider",
                resolved_provider_call[4].desc
            )
            assert.equal(true, resolved_provider_call[4].silent)
        end)
    end)
end)
