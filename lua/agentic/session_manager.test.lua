--- @diagnostic disable: invisible, missing-fields, assign-type-mismatch, cast-local-type, param-type-mismatch, need-check-nil, unnecessary-if
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local AgentModes = require("agentic.acp.agent_modes")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local SessionManager = require("agentic.session_manager")

--- @param mode_id string
--- @return agentic.acp.CurrentModeUpdate
local function mode_update(mode_id)
    return { sessionUpdate = "current_mode_update", currentModeId = mode_id }
end

describe("agentic.SessionManager", function()
    describe("_on_session_update: streamed agent messages", function()
        local function message_update(session_update, text)
            return {
                sessionUpdate = session_update,
                content = { type = "text", text = text },
            }
        end

        local function make_session(events)
            local write_message_chunk = spy.new(function(_writer, update)
                table.insert(
                    events,
                    "write:"
                        .. update.sessionUpdate
                        .. ":"
                        .. (update.content.text or update.content.type)
                )
                return update.content.text or "rendered-content"
            end)
            local append_agent_text = spy.new(function(_history, msg)
                table.insert(events, "history:" .. msg.type .. ":" .. msg.text)
            end)
            local render_header = spy.new(function() end)

            local session = {
                agent = { provider_config = { name = "test-provider" } },
                chat_history = { append_agent_text = append_agent_text },
                message_writer = {
                    write_message_chunk = write_message_chunk,
                },
                status_animation = { start = function() end },
                widget = { render_header = render_header },
            }
            setmetatable(session, { __index = SessionManager })
            return session, write_message_chunk, append_agent_text
        end

        it(
            "coalesces adjacent message chunks before a non-text update",
            function()
                local events = {}
                local session, write_message_chunk, append_agent_text =
                    make_session(events)

                local scheduled_callbacks = {}
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(callback)
                    table.insert(scheduled_callbacks, callback)
                end)

                SessionManager._on_session_update(
                    session,
                    message_update("agent_message_chunk", "Hello")
                )
                SessionManager._on_session_update(
                    session,
                    message_update("agent_message_chunk", " world")
                )

                assert.spy(write_message_chunk).was.called(0)
                assert.spy(append_agent_text).was.called(0)
                assert.equal(1, #scheduled_callbacks)

                -- A pure stream becomes visible at the end of this event-loop
                -- turn rather than waiting for a semantic update.
                scheduled_callbacks[1]()
                assert.spy(write_message_chunk).was.called(1)
                assert.spy(append_agent_text).was.called(1)

                SessionManager._on_session_update(session, {
                    sessionUpdate = "usage_update",
                })
                schedule_stub:revert()

                assert.spy(write_message_chunk).was.called(1)
                assert.spy(append_agent_text).was.called(1)
                local written = assert.not_nil(write_message_chunk.calls[1])
                assert.equal("Hello world", written[2].content.text)
                assert.same({
                    type = "agent",
                    text = "Hello world",
                    provider_name = "test-provider",
                }, append_agent_text.calls[1][2])
                assert.same({
                    "write:agent_message_chunk:Hello world",
                    "history:agent:Hello world",
                }, events)
            end
        )

        it(
            "preserves thought and message stream boundaries and ordering",
            function()
                local events = {}
                local session, write_message_chunk, append_agent_text =
                    make_session(events)

                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                SessionManager._on_session_update(
                    session,
                    message_update("agent_message_chunk", "answer")
                )
                SessionManager._on_session_update(
                    session,
                    message_update("agent_thought_chunk", "thinking")
                )
                SessionManager._on_session_update(
                    session,
                    message_update("agent_message_chunk", "continued")
                )
                SessionManager._on_session_update(session, {
                    sessionUpdate = "usage_update",
                })

                assert.spy(write_message_chunk).was.called(3)
                assert.spy(append_agent_text).was.called(3)
                assert.equal(
                    "agent_message_chunk",
                    write_message_chunk.calls[1][2].sessionUpdate
                )
                assert.equal(
                    "answer",
                    write_message_chunk.calls[1][2].content.text
                )
                assert.equal(
                    "agent_thought_chunk",
                    write_message_chunk.calls[2][2].sessionUpdate
                )
                assert.equal(
                    "thinking",
                    write_message_chunk.calls[2][2].content.text
                )
                assert.equal(
                    "agent_message_chunk",
                    write_message_chunk.calls[3][2].sessionUpdate
                )
                assert.equal(
                    "continued",
                    write_message_chunk.calls[3][2].content.text
                )
                assert.same({
                    "write:agent_message_chunk:answer",
                    "history:agent:answer",
                    "write:agent_thought_chunk:thinking",
                    "history:thought:thinking",
                    "write:agent_message_chunk:continued",
                    "history:agent:continued",
                }, events)
                schedule_stub:revert()
            end
        )

        it("records history for rendered non-text content", function()
            local events = {}
            local session, write_message_chunk, append_agent_text =
                make_session(events)

            SessionManager._on_session_update(session, {
                sessionUpdate = "agent_message_chunk",
                content = {
                    type = "image",
                    text = "image description",
                    data = "encoded",
                    mimeType = "image/png",
                },
            })

            assert.spy(write_message_chunk).was.called(1)
            assert.same({
                type = "agent",
                text = "image description",
                provider_name = "test-provider",
            }, append_agent_text.calls[1][2])
        end)
    end)

    describe("_on_session_update: current_mode_update", function()
        --- @type TestStub
        local notify_stub
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            notify_stub = spy.stub(Logger, "notify")
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local legacy_modes = AgentModes:new()
            legacy_modes:set_modes({
                availableModes = {
                    { id = "plan", name = "Plan", description = "Planning" },
                    { id = "code", name = "Code", description = "Coding" },
                },
                currentModeId = "plan",
            })

            local config_options = {
                legacy_agent_modes = legacy_modes,
            }
            function config_options:get_mode_name(mode_id)
                local _ = self
                local mode = legacy_modes:get_mode(mode_id)
                return mode and mode.name or nil
            end

            session = {
                config_options = config_options,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
            }
            setmetatable(session, { __index = SessionManager })
        end)

        after_each(function()
            notify_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("updates state, re-renders header, notifies user", function()
            SessionManager._on_session_update(session, mode_update("code"))

            assert.equal(
                "code",
                session.config_options.legacy_agent_modes.current_mode_id
            )

            assert.spy(render_header_spy).was.called(2)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.equal("Mode: Code", render_header_spy.calls[1][3])
            assert.is_nil(render_header_spy.calls[2][3])

            assert.spy(notify_stub).was.called(1)
            assert.equal("Mode changed to: code", notify_stub.calls[1][1])
            assert.equal(vim.log.levels.INFO, notify_stub.calls[1][2])
        end)

        it("rejects invalid mode and keeps current state", function()
            SessionManager._on_session_update(
                session,
                mode_update("nonexistent")
            )

            assert.equal(
                "plan",
                session.config_options.legacy_agent_modes.current_mode_id
            )
            assert.spy(render_header_spy).was.called(1)
            assert.is_nil(render_header_spy.calls[1][3])

            assert.spy(notify_stub).was.called(1)
            assert.equal(vim.log.levels.WARN, notify_stub.calls[1][2])
        end)
    end)

    describe("_on_session_update: config_option_update", function()
        --- @type TestSpy
        local render_header_spy
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr

        before_each(function()
            render_header_spy = spy.new(function() end)
            test_bufnr = vim.api.nvim_create_buf(false, true)

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
            }
            setmetatable(session, { __index = SessionManager })
        end)

        after_each(function()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("sets config options and updates header on mode", function()
            --- @type agentic.acp.ConfigOptionsUpdate
            local update = {
                sessionUpdate = "config_option_update",
                configOptions = {
                    {
                        id = "mode-1",
                        category = "mode",
                        currentValue = "plan",
                        description = "Mode",
                        name = "Mode",
                        options = {
                            {
                                value = "plan",
                                name = "Plan",
                                description = "",
                            },
                        },
                    },
                },
            }

            SessionManager._on_session_update(session, update)

            assert.is_not_nil(session.config_options.mode)
            assert.equal("plan", session.config_options.mode.currentValue)
            assert.spy(render_header_spy).was.called(2)
            assert.equal("Mode: Plan", render_header_spy.calls[1][3])
            assert.is_nil(render_header_spy.calls[2][3])
        end)
    end)

    describe("_handle_new_config_options", function()
        --- @type TestSpy
        local render_header_spy
        --- @type TestStub
        local defer_stub
        --- @type agentic.SessionManager
        local session
        --- @type integer
        local test_bufnr
        local original_headers

        before_each(function()
            render_header_spy = spy.new(function() end)
            defer_stub = spy.stub(vim, "defer_fn")
            defer_stub:invokes(function(fn, _ms)
                fn()
            end)
            test_bufnr = vim.api.nvim_create_buf(false, true)
            original_headers = Config.headers
            Config.headers = {
                chat = function(_parts)
                    return "custom"
                end,
            }

            local AgentConfigOptions =
                require("agentic.acp.agent_config_options")
            local BufHelpers = require("agentic.utils.buf_helpers")
            local keymap_stub = spy.stub(BufHelpers, "multi_keymap_set")

            local config_opts = AgentConfigOptions:new(
                { chat = test_bufnr },
                function() end,
                function() end
            )

            keymap_stub:revert()

            session = {
                _header_refresh_scheduled = false,
                config_options = config_opts,
                widget = {
                    render_header = render_header_spy,
                    buf_nrs = { chat = test_bufnr },
                },
            }
            setmetatable(session, { __index = SessionManager })
        end)

        after_each(function()
            Config.headers = original_headers
            defer_stub:revert()
            vim.api.nvim_buf_delete(test_bufnr, { force = true })
        end)

        it("refreshes custom headers when only model changes", function()
            SessionManager._handle_new_config_options(session, {
                {
                    id = "model",
                    category = "model",
                    currentValue = "gpt-5.4-high",
                    description = "Model",
                    name = "Model",
                    options = {
                        {
                            value = "gpt-5.4-high",
                            name = "GPT 5.4 High",
                            description = "",
                        },
                    },
                },
            })

            assert.is_not_nil(session.config_options.model)
            assert.equal(
                "gpt-5.4-high",
                session.config_options.model.currentValue
            )
            assert.spy(render_header_spy).was.called(1)
            assert.equal("chat", render_header_spy.calls[1][2])
            assert.is_nil(render_header_spy.calls[1][3])
        end)
    end)

    describe("_generate_welcome_header", function()
        it(
            "returns header with provider name, session id, and timestamp",
            function()
                local header = SessionManager._generate_welcome_header(
                    "Claude ACP",
                    "abc123"
                )

                assert.truthy(
                    header:match("^# Agentic %- Claude ACP %- abc123\n")
                )
                assert.truthy(header:match("\n%- %d%d%d%d%-%d%d%-%d%d"))
                assert.truthy(header:match("\n%-%-%- %-%-$"))
            end
        )

        it("uses 'unknown' when session_id is nil", function()
            local header =
                SessionManager._generate_welcome_header("Claude ACP", nil)

            assert.truthy(header:match("^# Agentic %- Claude ACP %- unknown\n"))
            assert.truthy(header:match("\n%-%-%- %-%-$"))
        end)
    end)

    describe("switch_provider", function()
        --- @type TestStub
        local notify_stub
        --- @type TestStub
        local get_instance_stub
        --- @type TestStub
        local schedule_stub
        local original_provider

        before_each(function()
            original_provider = Config.provider
            notify_stub = spy.stub(Logger, "notify")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            Config.provider = original_provider
            schedule_stub:revert()
            notify_stub:revert()
            if get_instance_stub then
                get_instance_stub:revert()
                get_instance_stub = nil
            end
        end)

        it(
            "no-ops when target provider already matches session provider",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                get_instance_stub = spy.stub(AgentInstance, "get_instance")

                Config.provider = "claude-acp"

                local session = {
                    is_generating = false,
                    session_id = nil,
                    _is_creating_session = true,
                    agent = {
                        provider_config = Config.acp_providers["claude-acp"],
                        cancel_session = spy.new(function() end),
                    },
                    permission_manager = { clear = spy.new(function() end) },
                    todo_list = { clear = spy.new(function() end) },
                    new_session = spy.new(function() end),
                }

                SessionManager.switch_provider(session, "claude-acp")

                assert.spy(notify_stub).was.called(0)
                assert.spy(get_instance_stub).was.called(0)
                assert.spy(session.agent.cancel_session).was.called(0)
                assert.spy(session.permission_manager.clear).was.called(0)
                assert.spy(session.todo_list.clear).was.called(0)
                assert.spy(session.new_session).was.called(0)
            end
        )

        it("blocks when is_generating is true", function()
            local session = {
                is_generating = true,
            }

            SessionManager.switch_provider(session, "gemini-acp")

            assert.spy(notify_stub).was.called(1)
            local msg = notify_stub.calls[1][1]
            assert.truthy(msg:match("[Gg]enerating"))
        end)

        it(
            "soft cancels old session without clearing widget/history",
            function()
                local cancel_spy = spy.new(function() end)
                local perm_clear_spy = spy.new(function() end)
                local todo_clear_spy = spy.new(function() end)
                local widget_clear_spy = spy.new(function() end)
                local file_list_clear_spy = spy.new(function() end)
                local code_selection_clear_spy = spy.new(function() end)

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local new_session_spy = spy.new(function() end)

                local original_messages = { { type = "user", text = "hello" } }
                local mock_chat_history = {
                    messages = original_messages,
                    session_id = "old-session",
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = cancel_spy,
                        provider_config = { name = "Old Provider" },
                    },
                    permission_manager = { clear = perm_clear_spy },
                    todo_list = { clear = todo_clear_spy },
                    widget = { clear = widget_clear_spy },
                    file_list = { clear = file_list_clear_spy },
                    code_selection = { clear = code_selection_clear_spy },
                    chat_history = mock_chat_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")

                assert.spy(cancel_spy).was.called(1)
                assert.is_nil(session.session_id)
                assert.spy(perm_clear_spy).was.called(1)
                assert.spy(todo_clear_spy).was.called(1)

                assert.spy(widget_clear_spy).was.called(0)
                assert.spy(file_list_clear_spy).was.called(0)
                assert.spy(code_selection_clear_spy).was.called(0)

                assert.equal(mock_new_agent, session.agent)

                assert.spy(new_session_spy).was.called(1)
                local opts = new_session_spy.calls[1][2]
                assert.is_true(opts.restore_mode)
                assert.equal("function", type(opts.on_created))
            end
        )

        it(
            "schedules history resend and sets _is_first_message in on_created",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local original_messages = { { type = "user", text = "hello" } }
                local saved_history = {
                    messages = original_messages,
                    session_id = "old",
                    get_replay_source = function()
                        return {
                            kind = "messages",
                            messages = original_messages,
                        }
                    end,
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",

                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")

                assert.is_not_nil(captured_on_created)

                local new_created_at = os.time()
                local new_updated_at = os.time()
                local ChatHistory = require("agentic.ui.chat_history")
                session.chat_history = ChatHistory:new()
                session.chat_history.session_id = "new"
                session.chat_history.created_at = new_created_at
                session.chat_history.updated_at = new_updated_at
                captured_on_created()

                assert.equal(0, #session.chat_history.messages)
                assert.equal(1, session.chat_history.message_count)
                assert.equal("new", session.chat_history.session_id)
                assert.equal(new_created_at, session.chat_history.created_at)
                assert.is_true(
                    session.chat_history.updated_at >= new_updated_at
                )
                assert.is_nil(session._history_to_send)
                assert.same(
                    { kind = "messages", messages = original_messages },
                    session._history_replay_source
                )
                assert.is_true(session._is_first_message)
            end
        )

        it(
            "stores a replay source instead of a whole history array on provider switch",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                local saved_history = {
                    messages = {},
                    message_count = 2,
                    session_id = "old",
                    get_replay_source = function()
                        return { kind = "messages", messages = {} }
                    end,
                }

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",
                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = saved_history,
                    _is_first_message = false,
                    _history_to_send = nil,
                    _history_replay_source = nil,
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")
                assert.is_not_nil(captured_on_created)

                local ChatHistory = require("agentic.ui.chat_history")
                session.chat_history = ChatHistory:new()
                session.chat_history.session_id = "new"
                session.chat_history.created_at = 1704067200
                session.chat_history.updated_at = 1704067200
                captured_on_created()

                assert.is_nil(session._history_to_send)
                assert.same(
                    { kind = "messages", messages = {} },
                    session._history_replay_source
                )
                assert.is_true(session._is_first_message)
            end
        )

        it(
            "aborts provider switch when replay history cannot be loaded",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                get_instance_stub = spy.stub(AgentInstance, "get_instance")

                local new_session_spy = spy.new(function() end)
                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-session",
                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = {
                        messages = {},
                        session_id = "missing-replay",
                        get_replay_source = function()
                            return {
                                kind = "jsonl",
                                session_id = "missing-replay",
                            }
                        end,
                    },
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")

                assert.spy(get_instance_stub).was.called(0)
                assert.spy(new_session_spy).was.called(0)
                assert.spy(notify_stub).was.called(1)
            end
        )

        it(
            "captures old replay source before assigning new provider session id",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local FileSystem = require("agentic.utils.file_system")
                local original_storage_path =
                    Config.session_restore.storage_path
                local temp_dir = vim.fn.tempname()
                vim.fn.mkdir(temp_dir, "p")
                Config.session_restore.storage_path = temp_dir
                local git_root_stub = spy.stub(FileSystem, "get_git_root")
                git_root_stub:returns("/test/project")

                local old_history = ChatHistory:new()
                old_history.session_id = "old-jsonl-session"
                old_history:add_message({
                    type = "user",
                    text = "old prompt",
                    timestamp = 1704067200,
                    provider_name = "Old",
                })

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-jsonl-session",
                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = old_history,
                    _is_first_message = false,
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")
                assert.is_not_nil(captured_on_created)

                session.chat_history = ChatHistory:new()
                session.chat_history.session_id = "new-jsonl-session"
                captured_on_created()

                assert.same({
                    kind = "messages",
                    messages = {
                        {
                            type = "user",
                            text = "old prompt",
                            timestamp = 1704067200,
                            provider_name = "Old",
                        },
                    },
                }, session._history_replay_source)

                git_root_stub:revert()
                Config.session_restore.storage_path = original_storage_path
                vim.fn.delete(temp_dir, "rf")
            end
        )

        it(
            "copies old replay history into new provider session JSONL",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local FileSystem = require("agentic.utils.file_system")
                local original_storage_path =
                    Config.session_restore.storage_path
                local temp_dir = vim.fn.tempname()
                vim.fn.mkdir(temp_dir, "p")
                Config.session_restore.storage_path = temp_dir
                local git_root_stub = spy.stub(FileSystem, "get_git_root")
                git_root_stub:returns("/test/project")

                local old_history = ChatHistory:new()
                old_history.session_id = "old-provider-session"
                old_history:add_message({
                    type = "user",
                    text = "provider old prompt",
                    timestamp = 1704067200,
                    provider_name = "Old",
                })

                local AgentInstance = require("agentic.acp.agent_instance")
                local mock_new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(_provider, on_ready)
                    on_ready(mock_new_agent)
                    return mock_new_agent
                end)

                local captured_on_created
                local new_session_spy = spy.new(function(_self, opts)
                    captured_on_created = opts.on_created
                end)

                Config.provider = "new-provider"

                local session = {
                    is_generating = false,
                    session_id = "old-provider-session",
                    agent = {
                        cancel_session = spy.new(function() end),
                        provider_config = { name = "Old" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = old_history,
                    _is_first_message = false,
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "new-provider")
                assert.is_not_nil(captured_on_created)

                session.chat_history = ChatHistory:new()
                session.chat_history.session_id = "new-provider-session"
                captured_on_created()

                local new_history =
                    ChatHistory.load_sync("new-provider-session")
                assert.is_not_nil(new_history)
                --- @cast new_history agentic.ui.ChatHistory
                assert.equal(1, #new_history.messages)
                local first_message = assert.not_nil(new_history.messages[1])
                assert.equal("provider old prompt", first_message.text)

                git_root_stub:revert()
                Config.session_restore.storage_path = original_storage_path
                vim.fn.delete(temp_dir, "rf")
            end
        )

        it("no-ops soft cancel when session_id is nil", function()
            local AgentInstance = require("agentic.acp.agent_instance")
            local mock_agent = {
                provider_config = { name = "Provider" },
                cancel_session = spy.new(function() end),
                create_session = spy.new(function() end),
            }
            get_instance_stub = spy.stub(AgentInstance, "get_instance")
            get_instance_stub:invokes(function(_provider, on_ready)
                on_ready(mock_agent)
                return mock_agent
            end)

            Config.provider = "some-provider"

            local session = {
                is_generating = false,
                session_id = nil,

                agent = mock_agent,
                permission_manager = { clear = spy.new(function() end) },
                todo_list = { clear = spy.new(function() end) },
                chat_history = { messages = {} },
                _is_first_message = false,
                _history_to_send = nil,
                new_session = spy.new(function() end),
            }

            SessionManager.switch_provider(session, "some-provider")

            assert.spy(mock_agent.cancel_session).was.called(0)
            assert.spy(session.permission_manager.clear).was.called(1)
            assert.spy(session.todo_list.clear).was.called(1)
            assert.spy(session.new_session).was.called(1)
        end)

        it(
            "ignores stale on_ready callbacks from earlier provider switches",
            function()
                local AgentInstance = require("agentic.acp.agent_instance")
                local ready_callbacks = {}
                local provider_agents = {
                    ["first-provider"] = {
                        provider_config = { name = "First Provider" },
                        cancel_session = spy.new(function() end),
                    },
                    ["second-provider"] = {
                        provider_config = { name = "Second Provider" },
                        cancel_session = spy.new(function() end),
                    },
                }
                get_instance_stub = spy.stub(AgentInstance, "get_instance")
                get_instance_stub:invokes(function(provider, on_ready)
                    ready_callbacks[provider] = on_ready
                    return provider_agents[provider]
                end)

                local new_session_spy = spy.new(function() end)
                local session = {
                    is_generating = false,
                    session_id = nil,
                    agent = {
                        provider_config = { name = "Original Provider" },
                    },
                    permission_manager = { clear = function() end },
                    todo_list = { clear = function() end },
                    chat_history = { messages = {} },
                    new_session = new_session_spy,
                }

                SessionManager.switch_provider(session, "first-provider")
                SessionManager.switch_provider(session, "second-provider")
                ready_callbacks["first-provider"](
                    provider_agents["first-provider"]
                )

                assert.equal(provider_agents["second-provider"], session.agent)
                assert.equal("second-provider", session.provider_name)
                assert.spy(new_session_spy).was.called(0)
            end
        )
    end)

    describe("get_new_session_reuse_reason", function()
        it("uses message_count when live messages are not retained", function()
            local session = {
                session_id = "session-1",
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                },
                chat_history = {
                    messages = {},
                    message_count = 1,
                },
                _is_creating_session = false,
            }

            assert.is_nil(
                SessionManager.get_new_session_reuse_reason(
                    session,
                    "claude-acp"
                )
            )
        end)

        it("reuses blank sessions for the same provider", function()
            local session = {
                session_id = "session-1",
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                },
                chat_history = { messages = {} },
                _is_creating_session = false,
            }

            assert.equal(
                "blank",
                SessionManager.get_new_session_reuse_reason(
                    session,
                    "claude-acp"
                )
            )
        end)

        it(
            "reuses sessions still being created for the same provider",
            function()
                local session = {
                    session_id = nil,
                    agent = {
                        provider_config = Config.acp_providers["claude-acp"],
                    },
                    chat_history = {
                        messages = { { type = "user", text = "hello" } },
                    },
                    _is_creating_session = true,
                }

                assert.equal(
                    "creating",
                    SessionManager.get_new_session_reuse_reason(
                        session,
                        "claude-acp"
                    )
                )
            end
        )

        it(
            "does not reuse sessions with messages once creation finished",
            function()
                local session = {
                    session_id = "session-1",
                    agent = {
                        provider_config = Config.acp_providers["claude-acp"],
                    },
                    chat_history = {
                        messages = { { type = "user", text = "hello" } },
                    },
                    _is_creating_session = false,
                }

                assert.is_nil(
                    SessionManager.get_new_session_reuse_reason(
                        session,
                        "claude-acp"
                    )
                )
            end
        )

        it("does not reuse sessions for a different provider", function()
            local session = {
                session_id = "session-1",
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                },
                chat_history = { messages = {} },
                _is_creating_session = true,
            }

            assert.is_nil(
                SessionManager.get_new_session_reuse_reason(
                    session,
                    "gemini-acp"
                )
            )
        end)

        it("does not reuse sessions before initial creation starts", function()
            local session = {
                session_id = nil,
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                },
                chat_history = { messages = {} },
                _is_creating_session = false,
            }

            assert.is_nil(
                SessionManager.get_new_session_reuse_reason(
                    session,
                    "claude-acp"
                )
            )
        end)
    end)

    describe("restore_from_history", function()
        --- @type string|nil
        local original_storage_path
        --- @type string|nil
        local temp_dir
        --- @type TestStub|nil
        local git_root_stub
        --- @type TestStub|nil
        local replay_stub

        before_each(function()
            local FileSystem = require("agentic.utils.file_system")
            original_storage_path = Config.session_restore.storage_path
            temp_dir = vim.fn.tempname()
            vim.fn.mkdir(temp_dir, "p")
            Config.session_restore.storage_path = temp_dir
            git_root_stub = spy.stub(FileSystem, "get_git_root")
            git_root_stub:returns("/test/project")

            local SessionRestore = require("agentic.session_restore")
            replay_stub =
                spy.stub(SessionRestore, "replay_messages_from_source")
        end)

        after_each(function()
            if replay_stub then
                replay_stub:revert()
                replay_stub = nil
            end
            if git_root_stub then
                git_root_stub:revert()
                git_root_stub = nil
            end
            if temp_dir then
                vim.fn.delete(temp_dir, "rf")
            end
            Config.session_restore.storage_path = original_storage_path
        end)

        local function create_loaded_history()
            local ChatHistory = require("agentic.ui.chat_history")
            local old_history = ChatHistory:new()
            old_history.session_id = "old-restore-session"
            old_history.title = "Old title"
            old_history.created_at = 1704067200
            old_history.updated_at = 1704067201
            old_history:add_message({
                type = "user",
                text = "old prompt",
                timestamp = 1704067200,
                provider_name = "Old Provider",
            })
            old_history:save(function(err)
                assert.is_nil(err)
            end)
            local loaded = ChatHistory.load_sync("old-restore-session")
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal(1, #loaded.messages)
            return loaded
        end

        it(
            "does not retain loaded transcript in live chat history after restore setup",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local loaded = create_loaded_history()

                local session = {
                    _restoring = false,
                    _replace_session = false,
                    _history_replay_source = nil,
                    _history_to_send = nil,
                    _is_first_message = true,
                    chat_history = ChatHistory:new(),
                    message_writer = {},
                    new_session = function(self, opts)
                        self.chat_history.session_id = "new-restore-session"
                        opts.on_created()
                    end,
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.restore_from_history(session, loaded, {
                    replace_session = false,
                })

                assert.equal(0, #session.chat_history.messages)
                assert.equal(1, session.chat_history.message_count)
                assert.same({
                    kind = "messages",
                    messages = loaded.messages,
                }, session._history_replay_source)
                assert.spy(assert.not_nil(replay_stub)).was.called(1)
            end
        )

        it(
            "copies replayed history into forked session JSONL without retaining it live",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local loaded = create_loaded_history()

                local session = {
                    _restoring = false,
                    _replace_session = false,
                    _history_replay_source = nil,
                    _history_to_send = nil,
                    _is_first_message = true,
                    chat_history = ChatHistory:new(),
                    message_writer = {},
                    new_session = function(self, opts)
                        self.chat_history.session_id = "forked-session"
                        opts.on_created()
                    end,
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.restore_from_history(session, loaded, {
                    replace_session = false,
                })

                local forked = ChatHistory.load_sync("forked-session")
                assert.is_not_nil(forked)
                --- @cast forked agentic.ui.ChatHistory
                assert.equal(1, #forked.messages)
                local first_message = assert.not_nil(forked.messages[1])
                assert.equal("old prompt", first_message.text)
                assert.equal(0, #session.chat_history.messages)
            end
        )

        it(
            "keeps continue-mode restored live history non-blank without retaining transcript",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local loaded = create_loaded_history()

                local session = {
                    _restoring = false,
                    _replace_session = false,
                    _history_replay_source = nil,
                    _history_to_send = nil,
                    _is_first_message = true,
                    chat_history = ChatHistory:new(),
                    message_writer = {},
                    new_session = function(self, opts)
                        self.chat_history.session_id = "temporary-new-session"
                        opts.on_created()
                    end,
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.restore_from_history(session, loaded, {
                    replace_session = true,
                })

                assert.equal(
                    "old-restore-session",
                    session.chat_history.session_id
                )
                assert.equal(0, #session.chat_history.messages)
                assert.equal(
                    loaded.message_count,
                    session.chat_history.message_count
                )
                assert.is_true(SessionManager.has_messages(session))
            end
        )
    end)

    describe("new_session", function()
        local original_provider

        before_each(function()
            original_provider = Config.provider
            Config.provider = "claude-acp"
        end)

        after_each(function()
            Config.provider = original_provider
        end)

        it("reuses when creation is already in progress", function()
            local session = {
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                    create_session = spy.new(function() end),
                },
                status_animation = { start = spy.new(function() end) },
                _is_creating_session = true,
                session_id = nil,
                chat_history = { messages = {} },
                _cancel_session = spy.new(function() end),
            }

            SessionManager.new_session(session)

            assert.spy(session._cancel_session).was.called(0)
            assert.spy(session.status_animation.start).was.called(0)
            assert.spy(session.agent.create_session).was.called(0)
        end)

        it("reuses blank created sessions", function()
            local session = {
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                    create_session = spy.new(function() end),
                },
                status_animation = { start = spy.new(function() end) },
                _is_creating_session = false,
                session_id = "session-1",
                chat_history = { messages = {} },
                _cancel_session = spy.new(function() end),
            }

            SessionManager.new_session(session)

            assert.spy(session._cancel_session).was.called(0)
            assert.spy(session.status_animation.start).was.called(0)
            assert.spy(session.agent.create_session).was.called(0)
        end)

        it("reuses blank sessions based on the session provider", function()
            Config.provider = "gemini-acp"

            local session = {
                agent = {
                    provider_config = Config.acp_providers["claude-acp"],
                    create_session = spy.new(function() end),
                },
                status_animation = { start = spy.new(function() end) },
                _is_creating_session = false,
                session_id = "session-1",
                chat_history = { messages = {} },
                _cancel_session = spy.new(function() end),
            }

            SessionManager.new_session(session)

            assert.spy(session._cancel_session).was.called(0)
            assert.spy(session.status_animation.start).was.called(0)
            assert.spy(session.agent.create_session).was.called(0)
        end)

        it("defers saving ACP session ID from provider response", function()
            local scheduled_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(scheduled_callbacks, callback)
            end)

            local save_spy = spy.new(function(_self, callback)
                if callback then
                    callback(nil)
                end
            end)
            local create_session_spy = spy.new(
                function(_self, _handlers, callback)
                    callback({
                        sessionId = "provider-session",
                    }, nil)
                end
            )

            local session = {
                agent = {
                    provider_config = {
                        name = "Test Provider",
                    },
                    create_session = create_session_spy,
                },
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                _is_creating_session = false,
                session_id = nil,
                chat_history = {
                    messages = {},
                    save = save_spy,
                },
                config_options = {
                    set_initial_mode = function() end,
                },
                message_writer = {
                    write_message = function() end,
                },
                _cancel_session = spy.new(function() end),
            }
            setmetatable(session, { __index = SessionManager })

            SessionManager.new_session(session)

            assert.equal("provider-session", session.session_id)
            assert.equal("provider-session", session.chat_history.session_id)
            assert.equal(
                "provider-session",
                session.chat_history.acp_session_id
            )
            assert.spy(save_spy).was.called(0)

            assert.equal(1, #scheduled_callbacks)
            scheduled_callbacks[1]()
            assert.spy(save_spy).was.called(1)

            schedule_stub:revert()
        end)

        it(
            "ignores scheduled setup from a superseded successful session creation",
            function()
                local scheduled_callbacks = {}
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(callback)
                    table.insert(scheduled_callbacks, callback)
                end)

                local on_created_spy = spy.new(function() end)
                local pending_input_spy = spy.new(function() end)
                local write_message_spy = spy.new(function() end)
                local save_spy = spy.new(function() end)
                local create_session_callback
                local create_session_spy = spy.new(
                    function(_self, _handlers, callback)
                        create_session_callback = callback
                    end
                )
                local session = {
                    _session_create_id = 0,
                    agent = {
                        provider_config = { name = "Test Provider" },
                        create_session = create_session_spy,
                    },
                    status_animation = {
                        start = spy.new(function() end),
                        stop = spy.new(function() end),
                    },
                    _is_creating_session = false,
                    session_id = nil,
                    chat_history = {
                        messages = {},
                        save = save_spy,
                    },
                    config_options = { set_initial_mode = function() end },
                    message_writer = { write_message = write_message_spy },
                    _cancel_session = spy.new(function() end),
                    _handle_input_submit = pending_input_spy,
                    _pending_input = "queued prompt",
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session, {
                    on_created = on_created_spy,
                })
                create_session_callback({ sessionId = "created-session" }, nil)

                assert.equal(1, #scheduled_callbacks)
                session._session_create_id = session._session_create_id + 1
                session.session_id = "replacement-session"
                scheduled_callbacks[1]()

                assert.spy(write_message_spy).was.called(0)
                assert.spy(on_created_spy).was.called(0)
                assert.spy(save_spy).was.called(0)
                assert.spy(pending_input_spy).was.called(0)
                assert.equal("queued prompt", session._pending_input)

                schedule_stub:revert()
            end
        )

        it(
            "cancels a pending permission once when replacing its session",
            function()
                local PermissionManager =
                    require("agentic.ui.permission_manager")
                local permission_callback
                local create_session_handlers = {}
                local create_session_spy = spy.new(
                    function(_self, handlers, _callback)
                        table.insert(create_session_handlers, handlers)
                    end
                )
                local provider_callback = spy.new(function() end)
                local clear_diff_spy = spy.new(function() end)
                local status_start_spy = spy.new(function() end)
                local writer = {
                    bufnr = 0,
                    display_permission_buttons = function()
                        return 1, 1, { [1] = "allow_once" }
                    end,
                    remove_permission_buttons = function() end,
                    set_on_content_changed = function() end,
                }

                local session = {
                    _session_create_id = 0,
                    agent = {
                        provider_config = { name = "Test Provider" },
                        create_session = create_session_spy,
                    },
                    status_animation = {
                        start = status_start_spy,
                        stop = spy.new(function() end),
                    },
                    permission_manager = PermissionManager:new(writer),
                    widget = { buf_nrs = { input = 0 } },
                    _show_diff_in_buffer = spy.new(function() end),
                    _clear_diff_in_buffer = clear_diff_spy,
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session, { skip_reuse_check = true })
                local request = {
                    sessionId = "created-session",
                    toolCall = { toolCallId = "tool-1" },
                    options = {
                        {
                            optionId = "allow_once",
                            name = "Allow once",
                            kind = "allow_once",
                        },
                    },
                }
                create_session_handlers[1].on_request_permission(
                    request,
                    provider_callback
                )
                permission_callback = assert.not_nil(
                    session.permission_manager.current_request
                ).callback

                SessionManager.new_session(session, {
                    skip_reuse_check = true,
                })
                assert.equal(2, #create_session_handlers)
                assert.spy(provider_callback).was.called(1)
                assert.is_nil(provider_callback.calls[1][2])

                local replacement_provider_callback = spy.new(function() end)
                create_session_handlers[2].on_request_permission(
                    request,
                    replacement_provider_callback
                )
                local replacement_callback = assert.not_nil(
                    session.permission_manager.current_request
                ).callback
                local clear_diff_count = clear_diff_spy.call_count
                local status_start_count = status_start_spy.call_count

                -- A delayed cancellation from the old request must not cancel
                -- the replacement request or apply stale UI effects.
                permission_callback(nil)
                permission_callback("allow_once")
                assert.spy(provider_callback).was.called(1)
                assert.spy(replacement_provider_callback).was.called(0)
                assert.equal(clear_diff_count, clear_diff_spy.call_count)
                assert.equal(status_start_count, status_start_spy.call_count)

                -- The reverse ordering must also remain idempotent: an
                -- approval can win before a duplicate cancellation arrives.
                replacement_callback("allow_once")
                assert.spy(replacement_provider_callback).was.called(1)
                replacement_callback(nil)
                assert.spy(replacement_provider_callback).was.called(1)
            end
        )

        it(
            "ignores session updates from a superseded session creation",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                local stale_update_handler
                local write_message_chunk_spy = spy.new(function() end)
                local create_session_spy = spy.new(
                    function(_self, handlers, _callback)
                        stale_update_handler = handlers.on_session_update
                    end
                )

                local session = {
                    _session_create_id = 0,
                    agent = {
                        provider_config = { name = "Test Provider" },
                        create_session = create_session_spy,
                    },
                    status_animation = {
                        start = spy.new(function() end),
                        stop = spy.new(function() end),
                    },
                    _is_creating_session = false,
                    session_id = nil,
                    chat_history = { messages = {} },
                    config_options = { set_initial_mode = function() end },
                    message_writer = {
                        write_message = function() end,
                        write_message_chunk = write_message_chunk_spy,
                    },
                    widget = { render_header = function() end },
                    _cancel_session = spy.new(function() end),
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session)
                session._session_create_id = session._session_create_id + 1

                stale_update_handler({
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "stale" },
                })

                assert.spy(write_message_chunk_spy).was.called(0)
                assert.is_nil(session._pending_agent_message_text)
                schedule_stub:revert()
            end
        )

        it("ignores stale session creation callbacks", function()
            local scheduled_callbacks = {}
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(callback)
                table.insert(scheduled_callbacks, callback)
            end)

            local create_session_callback
            local create_session_spy = spy.new(
                function(_self, _handlers, callback)
                    create_session_callback = callback
                end
            )
            local save_spy = spy.new(function() end)
            local pending_prompt_spy = spy.new(function() end)
            local cancel_session_spy = spy.new(function() end)

            local session = {
                _session_create_id = 0,
                agent = {
                    provider_config = {
                        name = "Stale Provider",
                    },
                    create_session = create_session_spy,
                    cancel_session = cancel_session_spy,
                },
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                _is_creating_session = false,
                session_id = nil,
                chat_history = {
                    messages = {},
                    save = save_spy,
                },
                config_options = {
                    set_initial_mode = function() end,
                },
                message_writer = {
                    write_message = function() end,
                },
                _cancel_session = spy.new(function() end),
                _handle_input_submit = pending_prompt_spy,
                _pending_input = "queued prompt",
            }
            setmetatable(session, { __index = SessionManager })

            SessionManager.new_session(session)
            session._session_create_id = session._session_create_id + 1
            create_session_callback({
                sessionId = "stale-session",
            }, nil)

            assert.is_nil(session.session_id)
            assert.equal("queued prompt", session._pending_input)
            assert.spy(save_spy).was.called(0)
            assert.spy(pending_prompt_spy).was.called(0)
            assert.equal(0, #scheduled_callbacks)

            -- The superseded session is orphaned agent-side unless cancelled.
            assert.spy(cancel_session_spy).was.called(1)
            local cancel_args = assert.not_nil(cancel_session_spy.calls[1])
            assert.equal("stale-session", cancel_args[2])

            schedule_stub:revert()
        end)

        it(
            "adopts legacy modes and models from a stale create response",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                local create_session_callback
                local create_session_spy = spy.new(
                    function(_self, _handlers, callback)
                        create_session_callback = callback
                    end
                )
                local set_legacy_modes_spy = spy.new(function() end)
                local set_legacy_models_spy = spy.new(function() end)
                local set_mode_to_chat_header_spy = spy.new(function() end)
                local cancel_session_spy = spy.new(function() end)

                local session = {
                    _session_create_id = 0,
                    agent = {
                        provider_config = { name = "Stale Provider" },
                        create_session = create_session_spy,
                        cancel_session = cancel_session_spy,
                    },
                    status_animation = {
                        start = spy.new(function() end),
                        stop = spy.new(function() end),
                    },
                    _is_creating_session = false,
                    session_id = nil,
                    chat_history = { messages = {}, save = function() end },
                    config_options = {
                        set_initial_mode = function() end,
                        set_legacy_modes = set_legacy_modes_spy,
                        set_legacy_models = set_legacy_models_spy,
                    },
                    message_writer = { write_message = function() end },
                    _cancel_session = spy.new(function() end),
                    _set_mode_to_chat_header = set_mode_to_chat_header_spy,
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session)
                -- Supersede the in-flight create, e.g. restore_from_history
                -- starting a fresh new_session before this one answered.
                session._session_create_id = session._session_create_id + 1

                create_session_callback({
                    sessionId = "stale-session",
                    modes = {
                        currentModeId = "chat",
                        availableModes = {
                            { id = "chat", name = "Chat" },
                            { id = "plan", name = "Plan" },
                        },
                    },
                    models = {
                        currentModelId = "sonnet",
                        availableModels = {},
                    },
                }, nil)

                -- Session state must not be adopted from the stale response.
                assert.is_nil(session.session_id)

                -- Agent-instance capabilities must be.
                assert.spy(set_legacy_modes_spy).was.called(1)
                local modes_args = assert.not_nil(set_legacy_modes_spy.calls[1])
                assert.equal("chat", modes_args[2].currentModeId)
                assert.spy(set_legacy_models_spy).was.called(1)
                assert.spy(set_mode_to_chat_header_spy).was.called(1)
                local header_args =
                    assert.not_nil(set_mode_to_chat_header_spy.calls[1])
                assert.equal("chat", header_args[2])

                assert.spy(cancel_session_spy).was.called(1)

                schedule_stub:revert()
            end
        )

        it("adopts configOptions from a stale create response", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function() end)

            local create_session_callback
            local create_session_spy = spy.new(
                function(_self, _handlers, callback)
                    create_session_callback = callback
                end
            )
            local handle_new_config_options_spy = spy.new(function() end)
            local set_legacy_modes_spy = spy.new(function() end)
            local set_legacy_models_spy = spy.new(function() end)
            local cancel_session_spy = spy.new(function() end)

            local session = {
                _session_create_id = 0,
                agent = {
                    provider_config = { name = "Stale Provider" },
                    create_session = create_session_spy,
                    cancel_session = cancel_session_spy,
                },
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                _is_creating_session = false,
                session_id = nil,
                chat_history = { messages = {}, save = function() end },
                config_options = {
                    set_initial_mode = function() end,
                    set_legacy_modes = set_legacy_modes_spy,
                    set_legacy_models = set_legacy_models_spy,
                },
                message_writer = { write_message = function() end },
                _cancel_session = spy.new(function() end),
                _handle_new_config_options = handle_new_config_options_spy,
            }
            setmetatable(session, { __index = SessionManager })

            local config_options = {
                { category = "mode", currentValue = "chat" },
            }

            SessionManager.new_session(session)
            session._session_create_id = session._session_create_id + 1

            create_session_callback({
                sessionId = "stale-session",
                configOptions = config_options,
            }, nil)

            assert.is_nil(session.session_id)
            assert.spy(handle_new_config_options_spy).was.called(1)
            local args = assert.not_nil(handle_new_config_options_spy.calls[1])
            assert.equal(config_options, args[2])

            -- The configOptions path must not touch the legacy setters.
            assert.spy(set_legacy_modes_spy).was.called(0)
            assert.spy(set_legacy_models_spy).was.called(0)

            assert.spy(cancel_session_spy).was.called(1)

            schedule_stub:revert()
        end)

        it("tolerates a stale create response that failed", function()
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function() end)

            local create_session_callback
            local create_session_spy = spy.new(
                function(_self, _handlers, callback)
                    create_session_callback = callback
                end
            )
            local cancel_session_spy = spy.new(function() end)

            local session = {
                _session_create_id = 0,
                agent = {
                    provider_config = { name = "Stale Provider" },
                    create_session = create_session_spy,
                    cancel_session = cancel_session_spy,
                },
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                _is_creating_session = false,
                session_id = "restored-session",
                chat_history = { messages = {}, save = function() end },
                config_options = { set_initial_mode = function() end },
                message_writer = { write_message = function() end },
                _cancel_session = spy.new(function() end),
            }
            setmetatable(session, { __index = SessionManager })

            SessionManager.new_session(session, { restore_mode = true })
            session._session_create_id = session._session_create_id + 1

            assert.has_no_errors(function()
                create_session_callback(nil, { message = "boom" })
            end)

            -- A failed stale create has no sessionId to cancel and must not
            -- wipe the session that superseded it.
            assert.equal("restored-session", session.session_id)
            assert.spy(cancel_session_spy).was.called(0)

            schedule_stub:revert()
        end)

        it(
            "cancels the orphaned session on the agent that created it after a provider switch",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                local create_session_callback
                local old_cancel_spy = spy.new(function() end)
                local new_cancel_spy = spy.new(function() end)

                local old_agent = {
                    provider_config = { name = "Old Provider" },
                    create_session = spy.new(
                        function(_self, _handlers, callback)
                            create_session_callback = callback
                        end
                    ),
                    cancel_session = old_cancel_spy,
                }
                local new_agent = {
                    provider_config = { name = "New Provider" },
                    create_session = spy.new(function() end),
                    cancel_session = new_cancel_spy,
                }

                local session = {
                    _session_create_id = 0,
                    agent = old_agent,
                    status_animation = {
                        start = spy.new(function() end),
                        stop = spy.new(function() end),
                    },
                    _is_creating_session = false,
                    session_id = nil,
                    chat_history = { messages = {}, save = function() end },
                    config_options = { set_initial_mode = function() end },
                    message_writer = { write_message = function() end },
                    _cancel_session = spy.new(function() end),
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session)

                -- Provider switch supersedes the create and swaps self.agent.
                session._session_create_id = session._session_create_id + 1
                session.agent = new_agent

                create_session_callback({ sessionId = "stale-session" }, nil)

                assert.spy(new_cancel_spy).was.called(0)
                assert.spy(old_cancel_spy).was.called(1)
                local cancel_args = assert.not_nil(old_cancel_spy.calls[1])
                assert.equal(old_agent, cancel_args[1])
                assert.equal("stale-session", cancel_args[2])

                schedule_stub:revert()
            end
        )

        --- Builds a session whose in-flight create belongs to `old_agent`,
        --- then simulates `switch_provider`: bump the create id and swap
        --- `self.agent` to a different agent instance.
        --- @param capability_response table Stale response fired afterwards
        --- @return table probes
        local function run_provider_switch_with_stale_create(
            capability_response
        )
            local create_session_callback
            local old_cancel_spy = spy.new(function() end)
            local probes = {
                set_legacy_modes = spy.new(function() end),
                set_legacy_models = spy.new(function() end),
                set_mode_to_chat_header = spy.new(function() end),
                handle_new_config_options = spy.new(function() end),
                old_cancel = old_cancel_spy,
            }

            local old_agent = {
                provider_config = { name = "Old Provider" },
                create_session = spy.new(function(_self, _handlers, callback)
                    create_session_callback = callback
                end),
                cancel_session = old_cancel_spy,
            }
            local new_agent = {
                provider_config = { name = "New Provider" },
                create_session = spy.new(function() end),
                cancel_session = spy.new(function() end),
            }

            local session = {
                _session_create_id = 0,
                agent = old_agent,
                status_animation = {
                    start = spy.new(function() end),
                    stop = spy.new(function() end),
                },
                _is_creating_session = false,
                session_id = nil,
                chat_history = { messages = {}, save = function() end },
                config_options = {
                    set_initial_mode = function() end,
                    set_legacy_modes = probes.set_legacy_modes,
                    set_legacy_models = probes.set_legacy_models,
                    -- Mode the live (new) provider already settled on.
                    mode = { currentValue = "plan" },
                },
                message_writer = { write_message = function() end },
                _cancel_session = spy.new(function() end),
                _set_mode_to_chat_header = probes.set_mode_to_chat_header,
                _handle_new_config_options = probes.handle_new_config_options,
            }
            setmetatable(session, { __index = SessionManager })

            SessionManager.new_session(session)

            session._session_create_id = session._session_create_id + 1
            session.agent = new_agent
            session.session_id = "new-sess"

            create_session_callback(capability_response, nil)

            probes.session = session
            return probes
        end

        -- The fork's monotonic create-id guard also fires on provider switch,
        -- where upstream's `session_id ~= nil` guard never could. Adopting
        -- capabilities there would overwrite the live provider's modes (and
        -- the chat header) with the dead provider's.
        it(
            "does not adopt legacy modes from a superseded provider but still cancels its orphan",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                local probes = run_provider_switch_with_stale_create({
                    sessionId = "stale-session",
                    modes = {
                        currentModeId = "chat",
                        availableModes = { { id = "chat", name = "Chat" } },
                    },
                    models = {
                        currentModelId = "haiku",
                        availableModels = {},
                    },
                })

                assert.spy(probes.set_legacy_modes).was.called(0)
                assert.spy(probes.set_legacy_models).was.called(0)
                assert.spy(probes.set_mode_to_chat_header).was.called(0)

                -- The live provider's mode survives untouched.
                assert.equal(
                    "plan",
                    probes.session.config_options.mode.currentValue
                )
                assert.equal("new-sess", probes.session.session_id)

                -- Cancelling the orphan is correct in every case, and is most
                -- necessary here.
                assert.spy(probes.old_cancel).was.called(1)
                local cancel_args = assert.not_nil(probes.old_cancel.calls[1])
                assert.equal("stale-session", cancel_args[2])

                schedule_stub:revert()
            end
        )

        it(
            "does not adopt configOptions from a superseded provider but still cancels its orphan",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function() end)

                local probes = run_provider_switch_with_stale_create({
                    sessionId = "stale-session",
                    configOptions = {
                        { category = "mode", currentValue = "chat" },
                    },
                })

                -- _handle_new_config_options also re-renders the chat header,
                -- so adopting here is visible to the user, not just internal.
                assert.spy(probes.handle_new_config_options).was.called(0)
                assert.equal(
                    "plan",
                    probes.session.config_options.mode.currentValue
                )

                assert.spy(probes.old_cancel).was.called(1)
                local cancel_args = assert.not_nil(probes.old_cancel.calls[1])
                assert.equal("stale-session", cancel_args[2])

                schedule_stub:revert()
            end
        )

        it(
            "stores terminal initial tool call payload before writer releases it",
            function()
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(callback)
                    callback()
                end)

                local write_tool_call_spy = spy.new(function(_, tool_call)
                    tool_call.body = nil
                    tool_call.diff = nil
                end)

                local create_session_spy = spy.new(
                    function(_self, handlers, callback)
                        handlers.on_tool_call({
                            tool_call_id = "terminal-initial",
                            kind = "execute",
                            status = "completed",
                            argument = "cmd",
                            body = { "line 1", "line 2" },
                        })
                        callback({
                            sessionId = "provider-session",
                        }, nil)
                    end
                )

                local history = {
                    messages = {},
                    save = function(_self, callback)
                        if callback then
                            callback(nil)
                        end
                    end,
                }
                function history:add_message(msg)
                    table.insert(self.messages, msg)
                end

                local session = {
                    _session_create_id = 0,
                    agent = {
                        provider_config = {
                            name = "Test Provider",
                        },
                        create_session = create_session_spy,
                    },
                    status_animation = {
                        start = spy.new(function() end),
                        stop = spy.new(function() end),
                    },
                    _is_creating_session = false,
                    session_id = nil,
                    chat_history = history,
                    config_options = {
                        set_initial_mode = function() end,
                    },
                    message_writer = {
                        write_tool_call_block = write_tool_call_spy,
                        write_message = function() end,
                    },
                    _cancel_session = spy.new(function() end),
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager.new_session(session)

                local tool_msg = assert.not_nil(history.messages[1])
                assert.equal("tool_call", tool_msg.type)
                assert.same({ "line 1", "line 2" }, tool_msg.body)
                assert.spy(write_tool_call_spy).was.called(1)

                schedule_stub:revert()
            end
        )
    end)

    describe("FileChangedShell autocommand", function()
        local Child = require("tests.helpers.child")
        local child = Child:new()

        before_each(function()
            child.setup()
        end)

        after_each(function()
            child.stop()
        end)

        it("sets fcs_choice to edit when FileChangedShell fires", function()
            child.v.fcs_choice = ""
            child.api.nvim_exec_autocmds("FileChangedShell", {
                group = "AgenticCleanup",
                pattern = "*",
            })

            assert.equal("edit", child.v.fcs_choice)
        end)
    end)

    describe("_handle_cursor_create_plan", function()
        --- @return table, table
        local function make_session()
            local captured = {}
            local session = {
                session_id = "session-1",
                message_writer = {
                    write_message = spy.new(function() end),
                },
                status_animation = {
                    stop = spy.new(function() end),
                    start = spy.new(function() end),
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    add_request = spy.new(function(_, request, callback, opts)
                        captured.request = request
                        captured.callback = callback
                        captured.opts = opts
                    end),
                },
                _show_diff_in_buffer = spy.new(function() end),
                _clear_diff_in_buffer = spy.new(function() end),
            }
            setmetatable(session, { __index = SessionManager })
            return session, captured
        end

        --- @return agentic.acp.CursorExtensionContext, TestSpy
        local function make_ctx()
            local respond_spy = spy.new(function() end)
            return {
                message_id = 7,
                method = "cursor/create_plan",
                params = {
                    plan = "Plan body",
                    todos = {},
                },
                respond = respond_spy,
            },
                respond_spy
        end

        it("queues plan options without provider auto approval", function()
            local session, captured = make_session()
            local ctx = make_ctx()

            SessionManager._handle_cursor_create_plan(session, ctx)

            assert.spy(session.permission_manager.add_request).was.called(1)
            assert.equal(
                "cursor_ext_plan_7",
                captured.request.toolCall.toolCallId
            )
            assert.same({ disable_auto_approve = true }, captured.opts)
        end)

        it("returns accepted when the approve option is selected", function()
            local session, captured = make_session()
            local ctx, respond_spy = make_ctx()

            SessionManager._handle_cursor_create_plan(session, ctx)
            captured.callback("approve")

            assert.spy(respond_spy).was.called(1)
            assert.equal("accepted", respond_spy.calls[1][1].outcome.outcome)
        end)

        it("returns rejected when the reject option is selected", function()
            local session, captured = make_session()
            local ctx, respond_spy = make_ctx()

            SessionManager._handle_cursor_create_plan(session, ctx)
            captured.callback("reject")

            assert.spy(respond_spy).was.called(1)
            assert.equal("rejected", respond_spy.calls[1][1].outcome.outcome)
        end)
    end)

    describe("_handle_cursor_ask_question", function()
        --- @return table, table
        local function make_session()
            local captured = {}
            local session = {
                session_id = "session-1",
                message_writer = {
                    write_message = spy.new(function() end),
                },
                status_animation = {
                    stop = spy.new(function() end),
                    start = spy.new(function() end),
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    add_request = spy.new(function(_, request, callback)
                        table.insert(captured, {
                            request = request,
                            callback = callback,
                        })
                    end),
                },
                _show_diff_in_buffer = spy.new(function() end),
                _clear_diff_in_buffer = spy.new(function() end),
            }
            setmetatable(session, { __index = SessionManager })
            return session, captured
        end

        it(
            "answers a structured question with the selected option id",
            function()
                local session, captured = make_session()
                local respond_spy = spy.new(function() end)
                local ctx = {
                    message_id = 8,
                    params = {
                        toolCallId = "call-1",
                        questions = {
                            {
                                id = "mode",
                                prompt = "Which mode?",
                                options = {
                                    { id = "agent", label = "Agent" },
                                    { id = "plan", label = "Plan" },
                                },
                            },
                        },
                    },
                    respond = respond_spy,
                }

                SessionManager._handle_cursor_ask_question(session, ctx)
                captured[1].callback("plan")

                assert.same({
                    outcome = {
                        outcome = "answered",
                        answers = {
                            {
                                questionId = "mode",
                                selectedOptionIds = { "plan" },
                            },
                        },
                    },
                }, respond_spy.calls[1][1])
            end
        )

        it("cancels payloads without structured questions", function()
            local session = make_session()
            local respond_spy = spy.new(function() end)
            local ctx = {
                params = {
                    question = "What should I do?",
                },
                respond = respond_spy,
            }

            SessionManager._handle_cursor_ask_question(session, ctx)

            assert.spy(session.message_writer.write_message).was.called(0)
            assert.same({
                outcome = { outcome = "cancelled" },
            }, respond_spy.calls[1][1])
        end)

        it("queues multiple structured questions sequentially", function()
            local session, captured = make_session()
            local respond_spy = spy.new(function() end)
            local ctx = {
                message_id = 9,
                params = {
                    toolCallId = "call-2",
                    questions = {
                        {
                            id = "first",
                            prompt = "First?",
                            options = { { id = "a", label = "A" } },
                        },
                        {
                            id = "second",
                            prompt = "Second?",
                            options = { { id = "b", label = "B" } },
                        },
                    },
                },
                respond = respond_spy,
            }

            SessionManager._handle_cursor_ask_question(session, ctx)
            captured[1].callback("a")
            captured[2].callback("b")

            assert.equal(2, #captured)
            assert.same({
                outcome = {
                    outcome = "answered",
                    answers = {
                        {
                            questionId = "first",
                            selectedOptionIds = { "a" },
                        },
                        {
                            questionId = "second",
                            selectedOptionIds = { "b" },
                        },
                    },
                },
            }, respond_spy.calls[1][1])
        end)

        it("cancels structured questions that require multi-select", function()
            local session = make_session()
            local respond_spy = spy.new(function() end)
            local ctx = {
                params = {
                    questions = {
                        {
                            id = "many",
                            prompt = "Choose all?",
                            allowMultiple = true,
                            options = { { id = "a", label = "A" } },
                        },
                    },
                },
                respond = respond_spy,
            }

            SessionManager._handle_cursor_ask_question(session, ctx)

            assert.same({
                outcome = { outcome = "cancelled" },
            }, respond_spy.calls[1][1])
        end)
    end)

    describe("on_tool_call_update: buffer reload", function()
        --- @type TestStub
        local checktime_stub
        --- @type TestStub
        local schedule_stub

        --- @param tool_call_blocks table<string, table>
        --- @return table<string, any>
        local function make_session(tool_call_blocks)
            return {
                message_writer = {
                    update_tool_call_block = function() end,
                    tool_call_blocks = tool_call_blocks,
                },
                permission_manager = {
                    current_request = nil,
                    queue = {},
                    remove_request_by_tool_call_id = function() end,
                },
                status_animation = { start = function() end },
                _clear_diff_in_buffer = function() end,
                chat_history = { update_tool_call = function() end },
            }
        end

        before_each(function()
            checktime_stub = spy.stub(vim.cmd, "checktime")
            schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)
        end)

        after_each(function()
            checktime_stub:revert()
            schedule_stub:revert()
        end)

        it(
            "does not persist a late diff after rendered diff payload release",
            function()
                local update_tool_call = spy.new(function() end)
                local history_update = spy.new(function() end)
                local session = make_session({
                    ["tc-diff"] = {
                        kind = "edit",
                        status = "completed",
                        _rendered_diff = true,
                    },
                })
                session.message_writer.update_tool_call_block = update_tool_call
                session.chat_history.update_tool_call = history_update

                SessionManager._on_tool_call_update(session, {
                    tool_call_id = "tc-diff",
                    status = "completed",
                    diff = { old = { "late" }, new = { "late" } },
                })

                local persisted = assert.not_nil(history_update.calls[1][3])
                assert.is_nil(persisted.diff)
            end
        )

        it(
            "records the first live update diff, but not a later diff",
            function()
                local history_update = spy.new(function() end)
                local session = make_session({
                    ["tc-live"] = {
                        kind = "edit",
                        status = "in_progress",
                    },
                })
                local update_tool_call = spy.new(function(_writer, update)
                    if update.diff then
                        session.message_writer.tool_call_blocks["tc-live"]._rendered_diff =
                            true
                    end
                end)
                session.message_writer.update_tool_call_block = update_tool_call
                session.chat_history.update_tool_call = history_update

                SessionManager._on_tool_call_update(session, {
                    tool_call_id = "tc-live",
                    status = "completed",
                    diff = { old = { "A old" }, new = { "A new" } },
                })
                assert.is_not_nil(history_update.calls[1][3].diff)

                SessionManager._on_tool_call_update(session, {
                    tool_call_id = "tc-live",
                    status = "completed",
                    diff = { old = { "B old" }, new = { "B new" } },
                })
                assert.is_nil(history_update.calls[2][3].diff)
            end
        )

        it("persists a later diff when metadata was never rendered", function()
            local update_tool_call = spy.new(function() end)
            local history_update = spy.new(function() end)
            local session = make_session({
                ["tc-diff"] = {
                    kind = "edit",
                    status = "in_progress",
                    diff = { old = { "metadata" }, new = { "only" } },
                    _rendered_diff = false,
                },
            })
            session.message_writer.update_tool_call_block = update_tool_call
            session.chat_history.update_tool_call = history_update

            SessionManager._on_tool_call_update(session, {
                tool_call_id = "tc-diff",
                status = "in_progress",
                diff = { old = { "later" }, new = { "diff" } },
            })

            local persisted = assert.not_nil(history_update.calls[1][3])
            assert.same({ old = { "later" }, new = { "diff" } }, persisted.diff)
        end)

        it("calls checktime for each file-mutating kind", function()
            for _, kind in ipairs({
                "edit",
                "create",
                "write",
                "delete",
                "move",
            }) do
                checktime_stub:reset()
                local tc_id = "tc-" .. kind
                local session = make_session({
                    [tc_id] = { kind = kind, status = "in_progress" },
                })

                SessionManager._on_tool_call_update(
                    session,
                    { tool_call_id = tc_id, status = "completed" }
                )

                assert.spy(checktime_stub).was.called(1)
            end
        end)

        it("cleans permission state when a tool call is cancelled", function()
            local remove_request = spy.new(function() end)
            local session = make_session({
                ["tc-1"] = { kind = "execute", status = "in_progress" },
            })
            session.permission_manager.remove_request_by_tool_call_id =
                remove_request

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "cancelled" }
            )

            assert.spy(remove_request).was.called(1)
            assert.equal("tc-1", remove_request.calls[1][2])
        end)

        it("does not call checktime for failed tool calls", function()
            local session = make_session({
                ["tc-1"] = { kind = "edit", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "failed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime for non-mutating kinds", function()
            local session = make_session({
                ["tc-1"] = { kind = "read", status = "in_progress" },
            })

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-1", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
        end)

        it("does not call checktime when tracker is missing", function()
            local debug_stub = spy.stub(Logger, "debug")
            local session = make_session({})

            SessionManager._on_tool_call_update(
                session,
                { tool_call_id = "tc-missing", status = "completed" }
            )

            assert.spy(checktime_stub).was.called(0)
            debug_stub:revert()
        end)
    end)

    describe("_cancel_session resets is_generating", function()
        --- @type TestStub
        local slash_commands_stub

        before_each(function()
            local SlashCommands = require("agentic.acp.slash_commands")
            slash_commands_stub = spy.stub(SlashCommands, "setCommands")
        end)

        after_each(function()
            slash_commands_stub:revert()
        end)

        it("resets is_generating to false", function()
            local ChatHistory = require("agentic.ui.chat_history")
            local session = {
                is_generating = true,
                _is_restoring_session = true,
                session_id = nil,
                permission_manager = {
                    clear = spy.new(function() end),
                },
                agent = {
                    cancel_session = spy.new(function() end),
                },
                widget = {
                    clear = spy.new(function() end),
                    buf_nrs = { input = 1 },
                },
                todo_list = { clear = function() end },
                file_list = { clear = function() end },
                code_selection = { clear = function() end },
                diagnostics_list = { clear = function() end },
                config_options = { clear = function() end },
                status_animation = { stop = spy.new(function() end) },
                chat_history = ChatHistory:new(),
                history_to_send = {},
                message_writer = {
                    reset_sender_tracking = function() end,
                },
            }

            SessionManager._cancel_session(session)

            assert.is_false(session.is_generating)
            assert.spy(session.status_animation.stop).was.called(1)
        end)

        it(
            "clears retained tool call blocks when cancelling an active session",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local session = {
                    is_generating = true,
                    session_id = "session-1",
                    permission_manager = {
                        clear = spy.new(function() end),
                    },
                    agent = {
                        cancel_session = spy.new(function() end),
                    },
                    widget = {
                        clear = spy.new(function() end),
                        buf_nrs = { input = 1 },
                    },
                    todo_list = { clear = function() end },
                    file_list = { clear = function() end },
                    code_selection = { clear = function() end },
                    diagnostics_list = { clear = function() end },
                    config_options = { clear = function() end },
                    status_animation = { stop = spy.new(function() end) },
                    chat_folds = { reset = function() end },
                    chat_history = ChatHistory:new(),
                    message_writer = {
                        clear_navigation_positions = function() end,
                        tool_call_blocks = {
                            ["tool-1"] = {
                                tool_call_id = "tool-1",
                                kind = "execute",
                                argument = "cmd",
                                body = { "large output" },
                            },
                        },
                    },
                }

                SessionManager._cancel_session(session)

                assert.equal(
                    0,
                    vim.tbl_count(session.message_writer.tool_call_blocks)
                )
            end
        )
    end)

    describe("_handle_input_submit /new while generating", function()
        it("allows /new even when is_generating is true", function()
            local new_session_spy = spy.new(function() end)

            local session = {
                is_generating = true,
                todo_list = { close_if_all_completed = function() end },
                new_session = new_session_spy,
            }

            SessionManager._handle_input_submit(session, "/new")

            assert.spy(new_session_spy).was.called(1)
        end)

        it("queues prompts while provider switch initializes", function()
            local notify_stub = spy.stub(Logger, "notify")
            local status_start_spy = spy.new(function() end)

            local session = {
                _is_switching_provider = true,
                _pending_input = nil,
                session_id = nil,
                status_animation = {
                    start = status_start_spy,
                },
                todo_list = { close_if_all_completed = function() end },
            }

            SessionManager._handle_input_submit(session, "hello")

            assert.equal("hello", session._pending_input)
            assert.spy(status_start_spy).was.called(1)
            assert.spy(notify_stub).was.called(0)

            notify_stub:revert()
        end)
    end)

    describe("_handle_input_submit selected code chat formatting", function()
        it(
            "uses four-backtick fences for selected code in the chat message",
            function()
                --- @type agentic.acp.UserMessageChunk|nil
                local written_message = nil

                local session = {
                    session_id = "test-session",
                    tab_page_id = 1,
                    _is_first_message = false,
                    _history_to_send = nil,
                    _replace_session = false,
                    todo_list = {
                        close_if_all_completed = function() end,
                    },
                    chat_history = {
                        title = "",
                        add_message = function() end,
                    },
                    code_selection = {
                        is_empty = function()
                            return false
                        end,
                        get_selections = function()
                            return {
                                {
                                    file_type = "lua",
                                    file_path = "lua/example.lua",
                                    start_line = 3,
                                    end_line = 4,
                                    lines = {
                                        "local value = 1",
                                        "return value",
                                    },
                                },
                            }
                        end,
                        clear = function() end,
                    },
                    file_list = {
                        is_empty = function()
                            return true
                        end,
                    },
                    diagnostics_list = {
                        is_empty = function()
                            return true
                        end,
                    },
                    agent = {
                        provider_config = { name = "Test Provider" },
                        send_prompt = function() end,
                    },
                    message_writer = {
                        record_prompt_position = function() end,
                        write_message = function(_, message)
                            written_message = message
                        end,
                        enable_auto_scroll = function() end,
                    },
                    status_animation = {
                        start = function() end,
                    },
                }

                SessionManager._handle_input_submit(session, "review this")

                assert.not_nil(written_message)
                assert.equal(
                    "````lua lua/example.lua#L3-L4\nlocal value = 1\nreturn value\n````",
                    written_message.content.text:match(
                        "````lua lua/example%.lua#L3%-L4\nlocal value = 1\nreturn value\n````"
                    )
                )
            end
        )
    end)

    describe("_handle_input_submit turn completion history", function()
        it(
            "does not let a late completion flush or finish a newer turn",
            function()
                local ChatHistory = require("agentic.ui.chat_history")
                local history = ChatHistory:new()
                local prompt_callbacks = {}
                local scheduled_callbacks = {}
                local write_message_spy = spy.new(function() end)
                local write_message_chunk_spy = spy.new(function() end)
                local schedule_stub = spy.stub(vim, "schedule")
                schedule_stub:invokes(function(fn)
                    table.insert(scheduled_callbacks, fn)
                end)

                local session
                session = {
                    session_id = "test-session",
                    tab_page_id = 1,
                    _is_first_message = false,
                    _history_to_send = nil,
                    _replace_session = false,
                    todo_list = {
                        close_if_all_completed = function() end,
                    },
                    chat_history = history,
                    code_selection = {
                        is_empty = function()
                            return true
                        end,
                        clear = function() end,
                    },
                    file_list = {
                        is_empty = function()
                            return true
                        end,
                    },
                    diagnostics_list = {
                        is_empty = function()
                            return true
                        end,
                    },
                    agent = {
                        provider_config = { name = "Test Provider" },
                        send_prompt = function(_, _, _, callback)
                            table.insert(prompt_callbacks, callback)
                        end,
                    },
                    message_writer = {
                        record_prompt_position = function() end,
                        write_message = write_message_spy,
                        write_message_chunk = write_message_chunk_spy,
                        enable_auto_scroll = function() end,
                    },
                    widget = { render_header = function() end },
                    status_animation = {
                        start = function() end,
                        stop = function() end,
                    },
                }
                setmetatable(session, { __index = SessionManager })

                SessionManager._handle_input_submit(session, "first turn")
                prompt_callbacks[1]({}, nil)
                SessionManager._handle_input_submit(session, "second turn")
                SessionManager._on_session_update(session, {
                    sessionUpdate = "agent_message_chunk",
                    content = { type = "text", text = "new turn response" },
                })

                local completion_callback =
                    assert.not_nil(scheduled_callbacks[1])
                completion_callback()

                assert.spy(write_message_spy).was.called(2)
                assert.spy(write_message_chunk_spy).was.called(0)
                assert.equal(
                    "new turn response",
                    session._pending_agent_message_text
                )
                assert.is_true(session.is_generating)
                assert.equal(2, history.message_count)

                schedule_stub:revert()
            end
        )

        it("stores the timestamp shown when a turn ends", function()
            local ChatHistory = require("agentic.ui.chat_history")
            local history = ChatHistory:new()
            local save_stub = spy.stub(history, "save")
            save_stub:invokes(function(_, callback)
                callback(nil)
            end)
            local prompt_callback
            local schedule_stub = spy.stub(vim, "schedule")
            schedule_stub:invokes(function(fn)
                fn()
            end)

            local session = {
                session_id = "test-session",
                tab_page_id = 1,
                _is_first_message = false,
                _history_to_send = nil,
                _replace_session = false,
                todo_list = {
                    close_if_all_completed = function() end,
                },
                chat_history = history,
                code_selection = {
                    is_empty = function()
                        return true
                    end,
                    clear = function() end,
                },
                file_list = {
                    is_empty = function()
                        return true
                    end,
                },
                diagnostics_list = {
                    is_empty = function()
                        return true
                    end,
                },
                agent = {
                    provider_config = { name = "Test Provider" },
                    send_prompt = function(_, _, _, callback)
                        prompt_callback = callback
                    end,
                },
                message_writer = {
                    record_prompt_position = function() end,
                    write_message = function() end,
                    enable_auto_scroll = function() end,
                },
                status_animation = {
                    start = function() end,
                    stop = function() end,
                },
            }

            SessionManager._handle_input_submit(session, "hello")
            assert.not_nil(prompt_callback)
            prompt_callback({}, nil)

            schedule_stub:revert()
            save_stub:revert()
            assert.equal(0, #history.messages)
            assert.equal(2, history.message_count)
            local turn_end_record = assert.not_nil(history._pending_records[2])
            local turn_end = assert.not_nil(turn_end_record.message)
            assert.equal("turn_end", turn_end.type)
            assert.equal("number", type(turn_end.timestamp))
            assert.equal("string", type(turn_end.duration))
        end)
    end)
end)
