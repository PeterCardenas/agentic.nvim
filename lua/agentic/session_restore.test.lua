--- @diagnostic disable: need-check-nil, param-type-mismatch
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

describe("SessionRestore", function()
    --- @type agentic.SessionRestore
    local SessionRestore
    local ChatHistory
    local SessionRegistry
    local Logger

    --- @type TestStub
    local chat_history_load_stub
    --- @type TestStub
    local chat_history_list_stub
    --- @type TestStub
    local session_registry_stub
    --- @type TestStub
    local logger_notify_stub
    --- @type TestStub
    local vim_ui_select_stub

    local test_sessions = {
        {
            session_id = "session-1",
            title = "First chat",
            timestamp = 1704067200,
        },
        {
            session_id = "session-2",
            title = "Second chat",
            timestamp = 1704153600,
        },
    }

    local mock_history = {
        session_id = "restored-session",
        timestamp = 1704067200,
        messages = { { type = "user", text = "Previous chat" } },
    }

    local function create_mock_session(opts)
        opts = opts or {}
        return {
            session_id = opts.session_id or "current-session",
            chat_history = opts.chat_history or { messages = {} },
            agent = { cancel_session = spy.new(function() end) },
            widget = {
                clear = spy.new(function() end),
                show = spy.new(function() end),
            },
            restore_from_history = spy.new(function() end),
        }
    end

    local function setup_list_stub(sessions)
        chat_history_list_stub:invokes(function(callback)
            callback(sessions or test_sessions)
        end)
    end

    local function setup_load_stub(history, err)
        chat_history_load_stub:invokes(function(_sid, callback)
            callback(history, err)
        end)
    end

    local function setup_registry_stub(session)
        session_registry_stub:invokes(function(_tab_id, callback)
            callback(session)
        end)
    end

    --- Get callback and items from vim.ui.select call at given index
    local function get_ui_select_call(index)
        --- @type fun(choice: table|nil): nil
        local callback = vim_ui_select_stub.calls[index][3]
        local items = vim_ui_select_stub.calls[index][1]
        return callback, items
    end

    --- Simulate selecting a session from the picker (first vim.ui.select call)
    local function select_session(session_item)
        local callback, _ = get_ui_select_call(1)
        callback(session_item)
    end

    before_each(function()
        package.loaded["agentic.session_restore"] = nil
        package.loaded["agentic.ui.chat_history"] = nil
        package.loaded["agentic.session_registry"] = nil
        package.loaded["agentic.utils.logger"] = nil

        SessionRestore = require("agentic.session_restore")
        ChatHistory = require("agentic.ui.chat_history")
        SessionRegistry = require("agentic.session_registry")
        Logger = require("agentic.utils.logger")

        chat_history_load_stub = spy.stub(ChatHistory, "load")
        chat_history_list_stub = spy.stub(ChatHistory, "list_sessions")
        session_registry_stub =
            spy.stub(SessionRegistry, "get_session_for_tab_page")
        logger_notify_stub = spy.stub(Logger, "notify")
        vim_ui_select_stub = spy.stub(vim.ui, "select")
    end)

    after_each(function()
        chat_history_load_stub:revert()
        chat_history_list_stub:revert()
        session_registry_stub:revert()
        logger_notify_stub:revert()
        vim_ui_select_stub:revert()
    end)

    describe("show_picker", function()
        it("notifies and skips picker when no sessions exist", function()
            setup_list_stub({})

            SessionRestore.show_picker(1)

            assert.spy(logger_notify_stub).was.called(1)
            assert.equal(
                "No saved sessions found",
                logger_notify_stub.calls[1][1]
            )
            assert.equal(vim.log.levels.INFO, logger_notify_stub.calls[1][2])
            assert.spy(vim_ui_select_stub).was.called(0)
        end)

        it("displays formatted sessions with date and title", function()
            setup_list_stub()

            SessionRestore.show_picker(1)

            local items = vim_ui_select_stub.calls[1][1]
            local opts = vim_ui_select_stub.calls[1][2]

            assert.equal(2, #items)
            assert.equal("session-1", items[1].session_id)
            assert.truthy(items[1].display:match("First chat"))
            assert.equal("Select session to restore:", opts.prompt)
            assert.equal(items[1].display, opts.format_item(items[1]))
        end)

        it("handles sessions with missing title", function()
            setup_list_stub({ { session_id = "s1" } })

            SessionRestore.show_picker(1)

            local items = vim_ui_select_stub.calls[1][1]
            assert.truthy(items[1].display:match("%(no title%)"))
        end)

        it("does nothing when user cancels session picker", function()
            setup_list_stub()

            SessionRestore.show_picker(1)

            select_session(nil)

            -- No restore attempted when session selection is cancelled
            assert.spy(vim_ui_select_stub).was.called(1)
            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it("restores selected session immediately in continue mode", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1)
            select_session({ session_id = "session-1" })

            assert.spy(vim_ui_select_stub).was.called(1)
            assert.spy(chat_history_load_stub).was.called(1)
            assert.spy(mock_session.restore_from_history).was.called(1)
            local restore_call = mock_session.restore_from_history.calls[1]
            assert.is_true(restore_call[3].replace_session)
        end)
    end)

    describe("restore with continue mode", function()
        it(
            "always cancels current session and passes replace_session=true",
            function()
                local mock_session = create_mock_session()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(1)

                select_session({ session_id = "session-1" })

                assert.spy(mock_session.agent.cancel_session).was.called(1)
                -- :cancel_session(id) → calls[1] = {self, id}
                assert.equal(
                    "current-session",
                    mock_session.agent.cancel_session.calls[1][2]
                )
                assert.spy(mock_session.widget.clear).was.called(1)
                assert.spy(mock_session.restore_from_history).was.called(1)

                local restore_call = mock_session.restore_from_history.calls[1]
                assert.equal(mock_history, restore_call[2])
                assert.is_true(restore_call[3].replace_session)
                assert.spy(mock_session.widget.show).was.called(1)
            end
        )

        it("cancels current session even when it has no messages", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1)

            select_session({ session_id = "session-1" })

            assert.spy(mock_session.agent.cancel_session).was.called(1)
            assert.spy(mock_session.widget.clear).was.called(1)
            assert.spy(mock_session.restore_from_history).was.called(1)

            local restore_call = mock_session.restore_from_history.calls[1]
            assert.is_true(restore_call[3].replace_session)
        end)
    end)

    describe("current session cancellation", function()
        it("skips cancel_session when session_id is nil", function()
            local mock_session = create_mock_session()
            mock_session.session_id = nil
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)

            SessionRestore.show_picker(1)

            select_session({ session_id = "session-1" })

            -- cancel_session not called because session_id is nil
            assert.spy(mock_session.agent.cancel_session).was.called(0)
            -- widget still cleared
            assert.spy(mock_session.widget.clear).was.called(1)
            assert.spy(mock_session.restore_from_history).was.called(1)
        end)
    end)

    describe("load failures", function()
        it("shows warning on load error", function()
            setup_list_stub()
            setup_load_stub(nil, "File not found")

            SessionRestore.show_picker(1)

            select_session({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("File not found")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
            assert.spy(session_registry_stub).was.called(0)
        end)

        it("shows warning on nil history without error", function()
            setup_list_stub()
            setup_load_stub(nil, nil)

            SessionRestore.show_picker(1)

            select_session({ session_id = "session-1" })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(logger_notify_stub.calls[1][1]:match("unknown error"))
            assert.spy(session_registry_stub).was.called(0)
        end)
    end)

    describe("session deletion (fzf-lua)", function()
        --- @type TestSpy
        local fzf_exec_spy
        --- @type TestStub
        local chat_history_delete_stub

        before_each(function()
            fzf_exec_spy = spy.new(function() end)
            package.loaded["fzf-lua"] = {
                fzf_exec = fzf_exec_spy,
            }

            chat_history_delete_stub = spy.stub(ChatHistory, "delete_session")
        end)

        after_each(function()
            package.loaded["fzf-lua"] = nil
            chat_history_delete_stub:revert()
        end)

        local function get_fzf_opts(call_index)
            return fzf_exec_spy.calls[call_index or 1][2]
        end

        local function get_fzf_actions(call_index)
            return get_fzf_opts(call_index).actions
        end

        --- Simulate fzf calling the content function to populate items
        local function populate_items(call_index)
            local contents_fn = fzf_exec_spy.calls[call_index or 1][1]
            local entries = {}
            contents_fn(function(entry)
                if entry then
                    table.insert(entries, entry)
                end
            end)
            return entries
        end

        --- @param entries string[]
        --- @param session_id string
        --- @return string|nil
        local function pick_entry(entries, session_id)
            for _, entry in ipairs(entries) do
                if entry:sub(1, #session_id + 1) == (session_id .. "\t") then
                    return entry
                end
            end
            return nil
        end

        it("passes content function to fzf_exec", function()
            setup_list_stub()
            SessionRestore.show_picker(1)

            assert.equal("function", type(fzf_exec_spy.calls[1][1]))
        end)

        it(
            "registers ctrl-x action with reload=true and header hint",
            function()
                setup_list_stub()
                SessionRestore.show_picker(1)

                local opts = get_fzf_opts()
                local ctrl_x = opts.actions["ctrl-x"]
                assert.is_table(ctrl_x)
                assert.equal("function", type(ctrl_x.fn))
                assert.is_true(ctrl_x.reload)
                assert.truthy(
                    opts.fzf_opts["--header"]:match(
                        "enter: continue selected session"
                    )
                )
                assert.truthy(
                    opts.fzf_opts["--header"]:match("ctrl%-x: delete")
                )
                assert.equal("\t", opts.fzf_opts["--delimiter"])
                assert.equal("2..", opts.fzf_opts["--with-nth"])
                assert.equal("function", type(opts.previewer))
            end
        )

        it("calls delete_session with correct session_id on ctrl-x", function()
            setup_list_stub()
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback(nil)
            end)

            SessionRestore.show_picker(1)

            -- Populate items so actions can resolve indices
            local entries = populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-1") })

            assert.spy(chat_history_delete_stub).was.called(1)
            assert.equal("session-1", chat_history_delete_stub.calls[1][1])
        end)

        it("deletes the correct session when second item selected", function()
            setup_list_stub()
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback(nil)
            end)

            SessionRestore.show_picker(1)
            local entries = populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-2") })

            assert.equal("session-2", chat_history_delete_stub.calls[1][1])
        end)

        it("reloads in-place instead of re-opening picker", function()
            setup_list_stub()
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback(nil)
            end)

            SessionRestore.show_picker(1)
            local entries = populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-1") })

            -- fzf_exec called only ONCE (reload is handled by fzf)
            assert.equal(1, fzf_exec_spy.call_count)
            -- Verify action has reload flag for fzf
            assert.is_true(actions["ctrl-x"].reload)
        end)

        it("shows success notification after deletion", function()
            setup_list_stub()
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback(nil)
            end)

            SessionRestore.show_picker(1)
            local entries = populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-1") })

            assert.is_true(
                logger_notify_stub:called_with(
                    "Session deleted",
                    vim.log.levels.INFO
                )
            )
        end)

        it("shows warning on delete failure", function()
            setup_list_stub()
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback("Permission denied")
            end)

            SessionRestore.show_picker(1)
            local entries = populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-1") })

            assert.spy(logger_notify_stub).was.called(1)
            assert.truthy(
                logger_notify_stub.calls[1][1]:match("Permission denied")
            )
            assert.equal(vim.log.levels.WARN, logger_notify_stub.calls[1][2])
        end)

        it("does nothing when ctrl-x with empty selection", function()
            setup_list_stub()

            SessionRestore.show_picker(1)
            populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({})

            assert.spy(chat_history_delete_stub).was.called(0)
        end)

        it("does nothing when ctrl-x with nil selection", function()
            setup_list_stub()

            SessionRestore.show_picker(1)
            populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn(nil)

            assert.spy(chat_history_delete_stub).was.called(0)
        end)

        it("does nothing when ctrl-x selection has no index match", function()
            setup_list_stub()

            SessionRestore.show_picker(1)
            populate_items()

            local actions = get_fzf_actions()
            actions["ctrl-x"].fn({ "not a valid entry" })

            assert.spy(chat_history_delete_stub).was.called(0)
        end)

        it(
            "does nothing when ctrl-x session_id is missing from current items",
            function()
                setup_list_stub()

                SessionRestore.show_picker(1)
                populate_items()

                local actions = get_fzf_actions()
                actions["ctrl-x"].fn({
                    "missing-session\tUnknown session",
                })

                assert.spy(chat_history_delete_stub).was.called(0)
            end
        )

        it(
            "default action restores selected session in continue mode",
            function()
                local mock_session = create_mock_session()
                setup_list_stub()
                setup_load_stub(mock_history)
                setup_registry_stub(mock_session)

                SessionRestore.show_picker(1)
                local entries = populate_items()

                local session_actions = get_fzf_actions()
                session_actions["default"]({ pick_entry(entries, "session-1") })
                assert.equal(1, fzf_exec_spy.call_count)
                assert.spy(chat_history_load_stub).was.called(1)
                assert.equal("session-1", chat_history_load_stub.calls[1][1])
                assert.spy(mock_session.restore_from_history).was.called(1)
                local restore_call = mock_session.restore_from_history.calls[1]
                assert.is_true(restore_call[3].replace_session)
            end
        )

        it("default action handles empty selection in fzf", function()
            setup_list_stub()

            SessionRestore.show_picker(1)
            populate_items()

            local actions = get_fzf_actions()
            actions["default"]({})

            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it("default action handles invalid selection format in fzf", function()
            setup_list_stub()

            SessionRestore.show_picker(1)
            populate_items()

            local actions = get_fzf_actions()
            actions["default"]({ "no index here" })

            assert.spy(chat_history_load_stub).was.called(0)
        end)

        it(
            "content function returns fresh items on simulated reload",
            function()
                local call_count = 0
                chat_history_list_stub:invokes(function(callback)
                    call_count = call_count + 1
                    if call_count <= 2 then
                        callback(test_sessions)
                    else
                        -- After deletion: only second session remains
                        callback({ test_sessions[2] })
                    end
                end)
                chat_history_delete_stub:invokes(function(_sid, callback)
                    callback(nil)
                end)

                SessionRestore.show_picker(1)

                -- Initial content generation
                local entries1 = populate_items()
                assert.equal(2, #entries1)

                -- Delete first session
                local actions = get_fzf_actions()
                actions["ctrl-x"].fn({ pick_entry(entries1, "session-1") })

                -- Simulate fzf reload: call content function again
                local entries2 = populate_items()
                assert.equal(1, #entries2)
                assert.truthy(
                    pick_entry(entries2, "session-2"):match("Second chat")
                )
            end
        )

        it("restores in continue mode after reload and select", function()
            local mock_session = create_mock_session()
            setup_list_stub()
            setup_load_stub(mock_history)
            setup_registry_stub(mock_session)
            chat_history_delete_stub:invokes(function(_sid, callback)
                callback(nil)
            end)

            SessionRestore.show_picker(42)

            -- Populate items and delete one
            local actions = get_fzf_actions()
            local entries = populate_items()
            actions["ctrl-x"].fn({ pick_entry(entries, "session-1") })

            -- Simulate reload and then select
            local reloaded_entries = populate_items()
            actions["default"]({ pick_entry(reloaded_entries, "session-2") })
            assert.equal(1, fzf_exec_spy.call_count)

            assert.spy(mock_session.restore_from_history).was.called(1)
            local restore_call = mock_session.restore_from_history.calls[1]
            assert.is_true(restore_call[3].replace_session)
        end)
    end)
end)
