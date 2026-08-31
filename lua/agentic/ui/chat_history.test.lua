local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local TEST_CWD = "/test/project"

describe("ChatHistory", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory
    local temp_dir
    local original_storage_path
    --- @type integer|nil
    local target_tab
    --- @type string|nil
    local target_cwd
    --- @type TestStub|nil
    local git_root_stub

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil

        temp_dir = vim.fn.tempname()
        vim.fn.mkdir(temp_dir, "p")

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = temp_dir

        local FileSystem = require("agentic.utils.file_system")
        git_root_stub = spy.stub(FileSystem, "get_git_root")
        git_root_stub:returns(TEST_CWD)

        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        if git_root_stub then
            git_root_stub:revert()
            git_root_stub = nil
        end
        if target_tab and vim.api.nvim_tabpage_is_valid(target_tab) then
            vim.api.nvim_set_current_tabpage(target_tab)
            vim.cmd("tabclose")
        end
        target_tab = nil
        if target_cwd then
            vim.fn.delete(target_cwd, "rf")
            target_cwd = nil
        end
        vim.fn.delete(temp_dir, "rf")
        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.ui.chat_history"] = nil
    end)

    describe("paths", function()
        it("uses JSONL as the runtime session file", function()
            local path = ChatHistory.get_file_path("session-abc")
            local project_folder = ChatHistory.get_project_folder()

            assert.truthy(path:match("^" .. vim.pesc(temp_dir)))
            assert.truthy(path:find(project_folder, 1, true))
            assert.truthy(path:match("session%-abc%.jsonl$"))
        end)

        it(
            "uses Neovim absolute-path detection for platform-native paths",
            function()
                local Config = require("agentic.config")
                local absolute_path =
                    vim.fn.fnamemodify("platform-sessions", ":p")
                Config.session_restore.storage_path = absolute_path
                local is_absolute_stub = spy.stub(vim.fn, "isabsolutepath")
                is_absolute_stub:returns(1)

                local root = ChatHistory.get_sessions_root()

                local call = assert.not_nil(is_absolute_stub.calls[1])
                assert.equal(absolute_path, call[1])
                assert.equal(absolute_path, root)
                is_absolute_stub:revert()
            end
        )

        it("captures a relative storage path as an absolute path", function()
            local Config = require("agentic.config")
            Config.session_restore.storage_path = "relative-sessions"

            local history = ChatHistory:new()

            assert.equal("/", history._sessions_folder:sub(1, 1))
            assert.equal("/", ChatHistory.get_sessions_root():sub(1, 1))
        end)

        it("resolves persistence from the target tab project", function()
            local current_tab = vim.api.nvim_get_current_tabpage()
            target_cwd = vim.fn.tempname()
            vim.fn.mkdir(target_cwd, "p")
            vim.cmd("tabnew")
            target_tab = vim.api.nvim_get_current_tabpage()
            vim.cmd("tcd " .. vim.fn.fnameescape(target_cwd))
            vim.api.nvim_set_current_tabpage(current_tab)
            assert.not_nil(git_root_stub):invokes(function(cwd)
                return cwd or TEST_CWD
            end)
            local Config = require("agentic.config")
            Config.session_restore.storage_path = "relative-sessions"

            local folder = ChatHistory.get_sessions_folder(target_tab)

            local normalized_target =
                target_cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
            vim.api.nvim_set_current_tabpage(target_tab)
            vim.cmd("tabclose")
            target_tab = nil
            vim.fn.delete(target_cwd, "rf")
            target_cwd = nil
            assert.truthy(folder:find(normalized_target, 1, true))
        end)
    end)

    describe("message operations", function()
        it(
            "loads with one root lookup and writes to the loaded folder",
            function()
                local folder =
                    vim.fs.joinpath(temp_dir, ChatHistory.get_project_folder())
                vim.fn.mkdir(folder, "p")
                local meta =
                    io.open(vim.fs.joinpath(folder, "loaded.meta.json"), "w")
                if not meta then
                    error("failed to create metadata")
                end
                meta:write(vim.json.encode({
                    session_id = "loaded",
                    title = "Loaded",
                    created_at = 1,
                    updated_at = 1,
                }))
                meta:close()
                local events =
                    io.open(vim.fs.joinpath(folder, "loaded.jsonl"), "w")
                if not events then
                    error("failed to create events")
                end
                events:write(vim.json.encode({
                    type = "message",
                    message = { type = "user", text = "hi" },
                }))
                events:close()
                local stub = git_root_stub
                if not stub then
                    error("git root stub unavailable")
                end
                stub:reset()
                local history = assert.not_nil(ChatHistory.load_sync("loaded"))
                assert.equal(1, stub.call_count)
                local root = "/changed/project"
                stub:invokes(function()
                    return root
                end)
                history:add_message({ type = "user", text = "later" })
                assert.is_not_nil(
                    vim.uv.fs_stat(vim.fs.joinpath(folder, "loaded.jsonl"))
                )
            end
        )

        it(
            "keeps instance persistence bound to its construction project",
            function()
                local root = TEST_CWD
                assert.not_nil(git_root_stub):invokes(function()
                    return root
                end)
                local history = ChatHistory:new()
                history.session_id = "stable-project"
                local original_path =
                    vim.fs.joinpath(temp_dir, ChatHistory.get_project_folder())
                root = "/later/project"
                history:add_message({
                    type = "user",
                    text = "stable",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })
                history:save()

                local later_path =
                    vim.fs.joinpath(temp_dir, ChatHistory.get_project_folder())
                root = TEST_CWD
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        vim.fs.joinpath(original_path, "stable-project.jsonl")
                    )
                )
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        vim.fs.joinpath(
                            original_path,
                            "stable-project.meta.json"
                        )
                    )
                )
                assert.is_nil(
                    vim.uv.fs_stat(
                        vim.fs.joinpath(later_path, "stable-project.jsonl")
                    )
                )
            end
        )

        it(
            "isolates histories constructed under different project roots",
            function()
                local root = TEST_CWD
                assert.not_nil(git_root_stub):invokes(function()
                    return root
                end)
                local first = ChatHistory:new()
                first.session_id = "first-project"
                root = "/other/project"
                local second = ChatHistory:new()
                second.session_id = "second-project"
                root = "/third/project"
                first:add_message({
                    type = "user",
                    text = "first",
                    timestamp = os.time(),
                    provider_name = "test",
                })
                second:add_message({
                    type = "user",
                    text = "second",
                    timestamp = os.time(),
                    provider_name = "test",
                })
                root = TEST_CWD
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_jsonl_file_path("first-project")
                    )
                )
                root = "/other/project"
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_jsonl_file_path("second-project")
                    )
                )
            end
        )

        it(
            "resolves the project root once per instance while static paths stay dynamic",
            function()
                local root = TEST_CWD
                assert.not_nil(git_root_stub):invokes(function()
                    return root
                end)
                local history = ChatHistory:new()
                history.session_id = "cached-root"
                root = "/later/project"
                history:add_message({
                    type = "user",
                    text = "cached",
                    timestamp = os.time(),
                    provider_name = "test",
                })
                history:save(function() end)
                assert.equal(1, assert.not_nil(git_root_stub).call_count)
                local dynamic_path = ChatHistory.get_jsonl_file_path("static")
                assert.truthy(dynamic_path:find("later_project", 1, true))
                assert.equal(2, assert.not_nil(git_root_stub).call_count)
            end
        )

        it("keeps live messages empty and tracks count cheaply", function()
            local history = ChatHistory:new()

            history:add_message({
                type = "user",
                text = "First",
                timestamp = os.time(),
                provider_name = "test-provider",
            })
            history:append_agent_text({
                type = "agent",
                text = "Second",
                provider_name = "test-provider",
            })

            assert.equal(0, #history.messages)
            assert.equal(2, history.message_count)
        end)

        it("compacts large tool call bodies before writing JSONL", function()
            local Config = require("agentic.config")
            local original_folding = Config.folding
            Config.folding = {
                tool_calls = {
                    enabled = true,
                    closed_by_default = false,
                    preview = true,
                    min_lines = 20,
                    max_display_lines = 2,
                },
            } --- @diagnostic disable-line: assign-type-mismatch

            local history = ChatHistory:new()
            history.session_id = "tool-jsonl"
            history:add_message({
                type = "user",
                text = "run tool",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:add_message({
                type = "tool_call",
                tool_call_id = "tc-large",
                status = "completed",
                kind = "execute",
                argument = "cmd",
                body = { "line 1", "line 2", "line 3", "line 4" },
            })
            history:update_tool_call("tc-large", {
                type = "tool_call",
                tool_call_id = "tc-large",
                status = "completed",
                body = { "line 1", "line 2", "line 3", "line 4" },
            })

            Config.folding = original_folding --- @diagnostic disable-line: assign-type-mismatch

            local records =
                vim.fn.readfile(ChatHistory.get_jsonl_file_path("tool-jsonl"))
            local message_record = vim.json.decode(records[2])
            local update_record = vim.json.decode(records[3])
            assert.is_true(#message_record.message.body <= 4)
            assert.is_true(#update_record.update.body <= 4)
        end)
    end)

    describe("save and load", function()
        it(
            "does not persist a session until the user sends a message",
            function()
                local history = ChatHistory:new()
                history.session_id = "agent-only"
                history:append_agent_text({
                    type = "agent",
                    text = "unsolicited",
                    provider_name = "test-provider",
                })

                --- @type string|nil
                local save_error = "not called"
                history:save(function(err)
                    save_error = err
                end)

                assert.is_nil(save_error)
                assert.is_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_jsonl_file_path("agent-only")
                    )
                )
                assert.is_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("agent-only")
                    )
                )
            end
        )

        it(
            "uses an empty replay source before the user sends a message",
            function()
                local history = ChatHistory:new()
                history.session_id = "blank-replay"
                history:append_agent_text({
                    type = "agent",
                    text = "unsolicited",
                    provider_name = "test-provider",
                })

                assert.same({
                    kind = "messages",
                    messages = {},
                }, history:get_replay_source())
            end
        )

        it("flushes earlier events when the user sends a message", function()
            local history = ChatHistory:new()
            history.session_id = "user-started"
            history:append_agent_text({
                type = "agent",
                text = "unsolicited",
                provider_name = "test-provider",
            })
            history:add_message({
                type = "user",
                text = "hello",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:save()

            local records =
                vim.fn.readfile(ChatHistory.get_jsonl_file_path("user-started"))
            assert.equal(2, #records)
            assert.equal("agent", vim.json.decode(records[1]).message.type)
            assert.equal("user", vim.json.decode(records[2]).message.type)
            assert.is_not_nil(
                vim.uv.fs_stat(
                    ChatHistory.get_metadata_file_path("user-started")
                )
            )
        end)

        it(
            "writes metadata separately from full-fidelity JSONL events",
            function()
                local history = ChatHistory:new()
                history.session_id = "split-save"
                history.title = "Split save"
                history:add_message({
                    type = "user",
                    text = "run tool",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tool-1",
                    status = "completed",
                    kind = "execute",
                    argument = "printf",
                    body = { "line 1", "line 2", "line 3" },
                })
                history:update_tool_call("tool-1", {
                    type = "tool_call",
                    tool_call_id = "tool-1",
                    body = { "line 1", "line 2", "line 3" },
                })
                history:save(function() end)

                local metadata_path =
                    ChatHistory.get_metadata_file_path("split-save")
                local metadata = vim.json.decode(
                    table.concat(vim.fn.readfile(metadata_path), "\n")
                )
                local records = vim.fn.readfile(
                    ChatHistory.get_jsonl_file_path("split-save")
                )

                assert.equal("split-save", metadata.session_id)
                assert.equal("Split save", metadata.title)
                assert.equal(3, #records)
                assert.equal("message", vim.json.decode(records[2]).type)
                assert.equal(
                    "tool_call_update",
                    vim.json.decode(records[3]).type
                )
                assert.equal(3, #vim.json.decode(records[2]).message.body)
            end
        )

        it(
            "loads split metadata and preserves message and tool-call records",
            function()
                local history = ChatHistory:new()
                history.session_id = "split-load"
                history.title = "Split load"
                history:add_message({
                    type = "user",
                    text = "run tool",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })
                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tool-2",
                    status = "pending",
                    body = { "result" },
                })
                history:update_tool_call("tool-2", {
                    type = "tool_call",
                    tool_call_id = "tool-2",
                    status = "completed",
                    body = { "result", "more" },
                })
                history:save(function() end)

                local loaded = ChatHistory.load_sync("split-load")

                assert.is_not_nil(loaded)
                --- @cast loaded agentic.ui.ChatHistory
                assert.equal("Split load", loaded.title)
                assert.equal(2, #loaded.messages)
                local tool_call = assert.not_nil(loaded.messages[2])
                assert.equal("completed", tool_call.status)
                assert.equal(2, #tool_call.body)
            end
        )

        it("updates external metadata on repeated saves", function()
            local history = ChatHistory:new()
            history.session_id = "repeated-save"
            history.title = "First title"
            history:add_message({
                type = "user",
                text = "first",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:save(function() end)

            history.title = "Second title"
            history:add_message({
                type = "agent",
                text = "response",
                provider_name = "test-provider",
            })
            history:save(function() end)

            local metadata = vim.json.decode(
                table.concat(
                    vim.fn.readfile(
                        ChatHistory.get_metadata_file_path("repeated-save")
                    ),
                    "\n"
                )
            )
            assert.equal("Second title", metadata.title)
            assert.equal(2, metadata.message_count)
        end)

        it("external metadata wins over embedded metadata", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local path = ChatHistory.get_jsonl_file_path("metadata-wins")
            local file = assert.not_nil(io.open(path, "w"))
            file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "hello",
                    timestamp = 2,
                    provider_name = "provider",
                },
            }))
            file:close()
            local metadata_file = assert.not_nil(
                io.open(
                    ChatHistory.get_metadata_file_path("metadata-wins"),
                    "w"
                )
            )
            metadata_file:write(vim.json.encode({
                session_id = "metadata-wins",
                title = "External title",
                created_at = 3,
                updated_at = 4,
                message_count = 1,
            }))
            metadata_file:close()

            local history =
                assert.not_nil(ChatHistory.load_sync("metadata-wins"))
            assert.equal("External title", history.title)
            assert.equal(3, history.created_at)
            assert.equal(4, history.updated_at)
        end)

        it(
            "rejects external metadata for a different session filename",
            function()
                local folder = ChatHistory.get_sessions_folder()
                vim.fn.mkdir(folder, "p")
                local path = ChatHistory.get_jsonl_file_path("requested")
                local file = assert.not_nil(io.open(path, "w"))
                file:write(vim.json.encode({
                    type = "message",
                    message = {
                        type = "user",
                        text = "hello",
                        timestamp = 2,
                        provider_name = "provider",
                    },
                }))
                file:close()

                local metadata_path =
                    ChatHistory.get_metadata_file_path("requested")
                local metadata_file =
                    assert.not_nil(io.open(metadata_path, "w"))
                metadata_file:write(vim.json.encode({
                    session_id = "other-session",
                    title = "Foreign title",
                    created_at = 3,
                    updated_at = 4,
                    message_count = 99,
                }))
                metadata_file:close()

                local history, err = ChatHistory.load_sync("requested")
                assert.is_nil(history)
                assert.equal("Invalid session metadata", err)

                local untouched = vim.json.decode(
                    table.concat(vim.fn.readfile(metadata_path), "\n")
                )
                assert.equal("other-session", untouched.session_id)
                assert.equal("Foreign title", untouched.title)
            end
        )

        it("rejects embedded metadata at runtime", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local path = ChatHistory.get_jsonl_file_path("requested")
            local file = assert.not_nil(io.open(path, "w"))
            file:write(vim.json.encode({
                type = "meta",
                session_id = "embedded-other",
                title = "Foreign embedded title",
                created_at = 3,
                updated_at = 4,
            }))
            file:write("\n")
            file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "hello",
                    timestamp = 5,
                    provider_name = "provider",
                },
            }))
            file:close()

            local metadata_path =
                ChatHistory.get_metadata_file_path("requested")
            local metadata_file = assert.not_nil(io.open(metadata_path, "w"))
            metadata_file:write(vim.json.encode({
                session_id = "requested",
                title = "External title",
                created_at = 6,
                updated_at = 7,
                message_count = 1,
            }))
            metadata_file:close()

            local history, err = ChatHistory.load_sync("requested")
            assert.is_nil(history)
            assert.equal("Event JSONL must not contain metadata", err)
        end)

        it("writes events before creating metadata on save", function()
            local history = ChatHistory:new()
            history.session_id = "ordered-save"
            history.title = "Ordered save"

            history:add_message({
                type = "user",
                text = "message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:save()

            assert.is_not_nil(
                vim.uv.fs_stat(ChatHistory.get_jsonl_file_path("ordered-save"))
            )
            assert.is_not_nil(
                vim.uv.fs_stat(
                    ChatHistory.get_metadata_file_path("ordered-save")
                )
            )

            history:save(function() end)
            assert.is_not_nil(
                vim.uv.fs_stat(
                    ChatHistory.get_metadata_file_path("ordered-save")
                )
            )
        end)

        it(
            "keeps later events queued after the first user append fails",
            function()
                local original_append_record = ChatHistory._append_record
                local append_attempt = 0
                local append_stub = spy.stub(ChatHistory, "_append_record")
                append_stub:invokes(function(history, record)
                    append_attempt = append_attempt + 1
                    if append_attempt == 2 then
                        return false, "append failed"
                    end
                    return original_append_record(history, record)
                end)

                local history = ChatHistory:new()
                history.session_id = "failed-first-user"
                vim.fn.delete(
                    ChatHistory.get_jsonl_file_path("failed-first-user")
                )
                vim.fn.delete(
                    ChatHistory.get_metadata_file_path("failed-first-user")
                )
                history:add_message({
                    type = "user",
                    text = "message",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "agent",
                    text = "response",
                    provider_name = "test-provider",
                })

                assert.equal(1, #history._pending_records)
                assert.equal(
                    "agent",
                    assert.not_nil(history._pending_records[1]).message.type
                )
                assert.is_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("failed-first-user")
                    )
                )

                append_stub:revert()
                --- @type string|nil
                local save_err = "not called"
                history:save(function(err)
                    save_err = err
                end)

                assert.is_nil(save_err)
                assert.equal(0, #history._pending_records)
                assert.is_nil(history._event_write_error)
                local records = vim.fn.readfile(
                    ChatHistory.get_jsonl_file_path("failed-first-user")
                )
                assert.equal(2, #records)
                assert.equal("user", vim.json.decode(records[1]).message.type)
                assert.equal("agent", vim.json.decode(records[2]).message.type)
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("failed-first-user")
                    )
                )
            end
        )

        it(
            "retains pending records when the real append write fails",
            function()
                local open_stub = spy.stub(io, "open")
                open_stub:invokes(function(path, mode)
                    if mode == "a" then
                        return {
                            write = function()
                                return nil, "simulated write failure"
                            end,
                            close = function()
                                return true
                            end,
                        }
                    end
                    return open_stub._original_fn(path, mode)
                end)

                local history = ChatHistory:new()
                history.session_id = "real-write-failure"
                history:add_message({
                    type = "user",
                    text = "message",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })

                local save_err = nil
                history:save(function(err)
                    save_err = err
                end)

                assert.equal("write failed: simulated write failure", save_err)
                assert.equal(1, #history._pending_records)
                assert.is_not_nil(history._event_write_error)
                assert.is_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("real-write-failure")
                    )
                )
                open_stub:revert()

                history:save(function(err)
                    save_err = err
                end)
                assert.is_nil(save_err)
                assert.equal(0, #history._pending_records)
                assert.is_nil(history._event_write_error)
                local records = vim.fn.readfile(
                    ChatHistory.get_jsonl_file_path("real-write-failure")
                )
                assert.equal(1, #records)
                assert.equal(
                    "message",
                    vim.json.decode(records[1]).message.text
                )
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("real-write-failure")
                    )
                )
            end
        )

        it("rolls back a partially written append before retrying", function()
            local history = ChatHistory:new()
            history.session_id = "partial-write-failure"
            local path = ChatHistory.get_jsonl_file_path(history.session_id)
            vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
            local existing_record = vim.json.encode({
                type = "message",
                message = {
                    type = "agent",
                    text = "prior",
                    provider_name = "test-provider",
                },
            })
            local existing = assert.not_nil(io.open(path, "w"))
            existing:write(existing_record)
            existing:close()

            local open_stub = spy.stub(io, "open")
            open_stub:invokes(function(open_path, mode)
                local file = open_stub._original_fn(open_path, mode)
                if open_path == path and mode == "a" and file then
                    local write_count = 0
                    return {
                        write = function(_, content)
                            write_count = write_count + 1
                            if write_count == 2 then
                                file:write(content:sub(1, 12))
                                return nil, "simulated partial write"
                            end
                            return file:write(content)
                        end,
                        close = function()
                            return file:close()
                        end,
                    }
                end
                return file
            end)

            history:add_message({
                type = "user",
                text = "message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })

            assert.equal(1, #history._pending_records)
            assert.same({ existing_record }, vim.fn.readfile(path))
            open_stub:revert()

            history:save()
            local records = vim.fn.readfile(path)
            assert.equal(2, #records)
            assert.equal(existing_record, records[1])
            assert.equal("message", vim.json.decode(records[2]).message.text)
        end)

        it(
            "does not mistake an identical preexisting tail for a committed append",
            function()
                local history = ChatHistory:new()
                history.session_id = "preexisting-close-failure"
                local path = ChatHistory.get_jsonl_file_path(history.session_id)
                vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
                local record = vim.json.encode({
                    type = "message",
                    message = {
                        type = "user",
                        text = "message",
                        timestamp = 1704067200,
                        provider_name = "test-provider",
                    },
                })
                local existing = assert.not_nil(io.open(path, "w"))
                existing:write(record)
                existing:close()

                local open_stub = spy.stub(io, "open")
                open_stub:invokes(function(open_path, mode)
                    if open_path == path and mode == "a" then
                        local file = open_stub._original_fn(open_path, mode)
                        return {
                            write = function(_, content)
                                return file:write(content)
                            end,
                            close = function()
                                return nil, "simulated close failure"
                            end,
                        }
                    end
                    return open_stub._original_fn(open_path, mode)
                end)

                history:add_message({
                    type = "user",
                    text = "message",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })
                local save_err = nil
                history:save(function(err)
                    save_err = err
                end)
                assert.truthy(save_err)
                assert.equal(1, #history._pending_records)
                open_stub:revert()

                history:save(function(err)
                    save_err = err
                end)
                assert.is_nil(save_err)
                local records = vim.fn.readfile(path)
                assert.equal(2, #records)
                assert.equal(record, records[1])
                assert.equal(record, records[2])
            end
        )

        it(
            "recognizes a committed append at the baseline offset when close reports failure",
            function()
                local open_stub = spy.stub(io, "open")
                open_stub:invokes(function(path, mode)
                    local file = open_stub._original_fn(path, mode)
                    if mode == "a" and file then
                        return {
                            write = function(_, content)
                                return file:write(content)
                            end,
                            close = function()
                                file:close()
                                return nil, "simulated close failure"
                            end,
                        }
                    end
                    return file
                end)

                local history = ChatHistory:new()
                history.session_id = "real-close-failure"
                local path = ChatHistory.get_jsonl_file_path(history.session_id)
                vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
                local existing = assert.not_nil(io.open(path, "w"))
                existing:write(vim.json.encode({
                    type = "message",
                    message = { type = "agent", text = "prior" },
                    timestamp = 1,
                    provider_name = "test-provider",
                }))
                existing:close()
                history:add_message({
                    type = "user",
                    text = "message",
                    timestamp = 1704067200,
                    provider_name = "test-provider",
                })
                local save_err = nil
                history:save(function(err)
                    save_err = err
                end)
                assert.is_nil(save_err)
                assert.equal(0, #history._pending_records)
                assert.is_nil(history._event_write_error)
                assert.is_not_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_metadata_file_path("real-close-failure")
                    )
                )
                open_stub:revert()

                history:save(function(err)
                    save_err = err
                end)
                assert.is_nil(save_err)
                local records = vim.fn.readfile(
                    ChatHistory.get_jsonl_file_path("real-close-failure")
                )
                assert.equal(2, #records)
                assert.equal("prior", vim.json.decode(records[1]).message.text)
                assert.equal(
                    "message",
                    vim.json.decode(records[2]).message.text
                )
            end
        )

        it("does not write metadata when event append fails", function()
            local append_stub = spy.stub(ChatHistory, "_append_record")
            append_stub:returns(false, "append failed")

            local history = ChatHistory:new()
            history.session_id = "failed-append"
            history.title = "Must not become an orphan"
            history:add_message({
                type = "user",
                text = "message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })

            local save_err = nil
            history:save(function(err)
                save_err = err
            end)

            assert.is_not_nil(save_err)
            assert.is_nil(
                vim.uv.fs_stat(
                    ChatHistory.get_metadata_file_path("failed-append")
                )
            )
            append_stub:revert()
        end)

        it("rejects mixed JSONL when metadata sidecar is missing", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local path = ChatHistory.get_jsonl_file_path("repair-on-load")
            local file = assert.not_nil(io.open(path, "w"))
            file:write(vim.json.encode({
                type = "meta",
                session_id = "repair-on-load",
                title = "Recovered",
                created_at = 1,
                updated_at = 2,
            }))
            file:write("\n")
            file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "hello",
                    timestamp = 2,
                    provider_name = "provider",
                },
            }))
            file:close()

            local history, err = ChatHistory.load_sync("repair-on-load")
            assert.is_nil(history)
            assert.equal("Invalid session metadata", err)
            assert.is_nil(
                vim.uv.fs_stat(
                    ChatHistory.get_metadata_file_path("repair-on-load")
                )
            )
        end)

        it(
            "rejects invalid external metadata without overwriting it",
            function()
                local folder = ChatHistory.get_sessions_folder()
                vim.fn.mkdir(folder, "p")
                local path = ChatHistory.get_jsonl_file_path("repair-bad-meta")
                local file = assert.not_nil(io.open(path, "w"))
                file:write(vim.json.encode({
                    type = "meta",
                    session_id = "repair-bad-meta",
                    title = "Recovered",
                    created_at = 1,
                    updated_at = 2,
                }))
                file:write("\n")
                file:write(vim.json.encode({
                    type = "message",
                    message = {
                        type = "user",
                        text = "hello",
                        timestamp = 2,
                        provider_name = "provider",
                    },
                }))
                file:close()

                local metadata_file = assert.not_nil(
                    io.open(
                        ChatHistory.get_metadata_file_path("repair-bad-meta"),
                        "w"
                    )
                )
                metadata_file:write("{bad metadata")
                metadata_file:close()

                local history, err = ChatHistory.load_sync("repair-bad-meta")
                assert.is_nil(history)
                assert.equal("Invalid session metadata", err)
                assert.equal(
                    "{bad metadata",
                    table.concat(
                        vim.fn.readfile(
                            ChatHistory.get_metadata_file_path(
                                "repair-bad-meta"
                            )
                        ),
                        "\n"
                    )
                )
            end
        )

        it("leaves no temporary metadata files after saving", function()
            local history = ChatHistory:new()
            history.session_id = "no-temp-artifacts"
            history.title = "No temp files"
            history:add_message({
                type = "user",
                text = "message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:save(function() end)

            local names = {}
            for name in vim.fs.dir(ChatHistory.get_sessions_folder()) do
                names[name] = true
            end
            assert.is_true(names["no-temp-artifacts.jsonl"])
            assert.is_true(names["no-temp-artifacts.meta.json"])
            for name in pairs(names) do
                assert.is_nil(
                    name:match("^no%-temp%-artifacts%.meta%.json%.tmp%.")
                )
            end
        end)

        it("persists JSONL only and restores messages transiently", function()
            local original = ChatHistory:new()
            original.session_id = "roundtrip-test"
            original.title = "Roundtrip"
            original:add_message({
                type = "user",
                text = "Test message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })

            --- @type string|nil
            local save_err = "not-called"
            original:save(function(err)
                save_err = err
            end)
            assert.is_nil(save_err)

            local jsonl_path = ChatHistory.get_jsonl_file_path("roundtrip-test")
            local split_path = vim.fs.joinpath(
                ChatHistory.get_sessions_folder(),
                "roundtrip-test.json"
            )
            local metadata_path = vim.fs.joinpath(
                ChatHistory.get_sessions_folder(),
                "roundtrip-test.meta.json"
            )

            assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
            assert.is_nil(vim.uv.fs_stat(split_path))
            assert.is_not_nil(vim.uv.fs_stat(metadata_path))

            local loaded = nil
            local load_err = nil
            local done = false
            ChatHistory.load("roundtrip-test", function(history, err)
                loaded = history
                load_err = err
                done = true
            end)
            vim.wait(1000, function()
                return done
            end)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal("roundtrip-test", loaded.session_id)
            assert.equal("Roundtrip", loaded.title)
            assert.equal(1, #loaded.messages)
            local first_loaded_message = assert.not_nil(loaded.messages[1])
            assert.equal("Test message", first_loaded_message.text)
        end)

        it(
            "collects replay messages from the source project after a project switch",
            function()
                local root_stub = assert.not_nil(git_root_stub)
                local project_a = TEST_CWD
                local project_b = "/test/project-b"
                root_stub:returns(project_a)
                local history = ChatHistory:new()
                vim.fn.mkdir(history._sessions_folder, "p")
                history.session_id = "replay-project"
                history:add_message({
                    type = "user",
                    text = "From project A",
                    timestamp = 1704067200,
                    provider_name = "test",
                })
                history:save(function(err)
                    assert.is_nil(err)
                end)
                local source = history:get_replay_source()

                root_stub:returns(project_b)
                local messages, err = ChatHistory.collect_messages(source)

                assert.is_nil(err)
                local collected_messages = assert.not_nil(messages)
                local message = assert.not_nil(collected_messages[1])
                assert.equal("From project A", message.text)
            end
        )

        it(
            "keeps metadata and events in the captured project during async load",
            function()
                local session_id = "project-switch"
                local function write(path, value)
                    vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
                    local file = assert.not_nil(io.open(path, "w"))
                    file:write(vim.json.encode(value))
                    file:close()
                end

                local root_stub = assert.not_nil(git_root_stub)
                local project_a = ChatHistory.get_sessions_folder()
                root_stub:returns("/test/project-b")
                local project_b = ChatHistory.get_sessions_folder()
                root_stub:returns(TEST_CWD)

                write(vim.fs.joinpath(project_a, session_id .. ".meta.json"), {
                    session_id = session_id,
                    title = "Project A",
                    created_at = 1704067200,
                    updated_at = 1704067201,
                })
                write(vim.fs.joinpath(project_a, session_id .. ".jsonl"), {
                    type = "message",
                    message = {
                        type = "user",
                        text = "From project A",
                        timestamp = 1704067200,
                        provider_name = "test",
                    },
                })
                write(vim.fs.joinpath(project_b, session_id .. ".jsonl"), {
                    type = "message",
                    message = {
                        type = "user",
                        text = "From project B",
                        timestamp = 1704067200,
                        provider_name = "test",
                    },
                })

                local root_calls = 0
                root_stub:invokes(function()
                    root_calls = root_calls + 1
                    return root_calls == 1 and TEST_CWD or "/test/project-b"
                end)
                local loaded = nil
                local done = false
                ChatHistory.load(session_id, function(history)
                    loaded = history
                    done = true
                end)
                vim.wait(1000, function()
                    return done
                end)

                assert.equal(1, root_calls)
                assert.is_not_nil(loaded)
                --- @cast loaded agentic.ui.ChatHistory
                assert.equal("Project A", loaded.title)
                local first_message = assert.not_nil(loaded.messages[1])
                assert.equal("From project A", first_message.text)

                root_stub:returns("/test/project-b")
                loaded:add_message({
                    type = "user",
                    text = "Written to project A",
                    timestamp = 1704067202,
                    provider_name = "test",
                })
                local project_a_events = vim.fn.readfile(
                    vim.fs.joinpath(project_a, session_id .. ".jsonl")
                )
                assert.equal(2, #project_a_events)
                local project_b_events = vim.fn.readfile(
                    vim.fs.joinpath(project_b, session_id .. ".jsonl")
                )
                assert.equal(1, #project_b_events)
            end
        )

        it("coalesces streamed agent chunks when loading JSONL", function()
            local path = ChatHistory.get_jsonl_file_path("jsonl-load-test")
            vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
            local file = io.open(path, "w")
            assert.is_not_nil(file)
            if not file then
                error("failed to create jsonl fixture")
            end
            file:write(table.concat({
                vim.json.encode({
                    type = "message",
                    message = {
                        type = "agent",
                        text = "Hello",
                        provider_name = "test-provider",
                    },
                }),
                vim.json.encode({
                    type = "message",
                    message = {
                        type = "agent",
                        text = " world",
                        provider_name = "test-provider",
                    },
                }),
            }, "\n"))
            file:close()
            local metadata_file = assert.not_nil(
                io.open(
                    ChatHistory.get_metadata_file_path("jsonl-load-test"),
                    "w"
                )
            )
            metadata_file:write(vim.json.encode({
                session_id = "jsonl-load-test",
                title = "JSONL load",
                created_at = 1704067200,
                updated_at = 1704067201,
                message_count = 2,
            }))
            metadata_file:close()

            local loaded = ChatHistory.load_sync("jsonl-load-test")

            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal(1, #loaded.messages)
            local first_loaded_message = assert.not_nil(loaded.messages[1])
            assert.equal("Hello world", first_loaded_message.text)
        end)

        it("returns an error for missing or corrupted JSONL", function()
            local path = ChatHistory.get_jsonl_file_path("corrupted")
            vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
            local file = io.open(path, "w")
            assert.is_not_nil(file)
            if not file then
                error("failed to create corrupt jsonl")
            end
            file:write("{not valid")
            file:close()

            local missing, missing_err = ChatHistory.load_sync("missing")
            local corrupted, corrupted_err = ChatHistory.load_sync("corrupted")

            assert.is_nil(missing)
            assert.is_not_nil(missing_err)
            assert.is_nil(corrupted)
            assert.is_not_nil(corrupted_err)
        end)

        it("returns load errors from collect_messages", function()
            local messages, err = ChatHistory.collect_messages({
                kind = "jsonl",
                session_id = "missing",
            })

            assert.is_nil(messages)
            assert.is_not_nil(err)
        end)

        it("rejects sidecar metadata with an unexpected type", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local metadata_file = assert.not_nil(
                io.open(
                    ChatHistory.get_metadata_file_path("unexpected-type"),
                    "w"
                )
            )
            metadata_file:write(vim.json.encode({
                type = "message",
                session_id = "unexpected-type",
                title = "Unexpected",
                created_at = 1,
                updated_at = 2,
            }))
            metadata_file:close()
            local jsonl_file = assert.not_nil(
                io.open(ChatHistory.get_jsonl_file_path("unexpected-type"), "w")
            )
            jsonl_file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "message",
                    timestamp = 1,
                    provider_name = "test",
                },
            }))
            jsonl_file:close()

            local history, err = ChatHistory.load_sync("unexpected-type")

            assert.is_nil(history)
            assert.equal("Invalid session metadata", err)
        end)
    end)

    describe("list and delete", function()
        local function save_session(session_id, title, updated_at)
            local history = ChatHistory:new()
            history.session_id = session_id
            history.title = title
            history.created_at = math.floor(updated_at - 1)
            history.updated_at = updated_at
            history:add_message({
                type = "user",
                text = title,
                timestamp = updated_at,
                provider_name = "test-provider",
            })
            history:save(function() end)
        end

        it("lists JSONL sessions sorted by updated_at", function()
            save_session("session-old", "Old", 1704067200)
            save_session("session-new", "New", 1704153600)

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            vim.wait(1000, function()
                return sessions ~= nil
            end)

            assert.is_not_nil(sessions)
            --- @cast sessions agentic.ui.ChatHistory.SessionMeta[]
            assert.equal(2, #sessions)
            local first_session = assert.not_nil(sessions[1])
            local second_session = assert.not_nil(sessions[2])
            assert.equal("session-new", first_session.session_id)
            assert.equal("New", first_session.title)
            assert.equal("session-old", second_session.session_id)
        end)

        it("lists metadata without parsing the full JSONL history", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local session_file =
                io.open(vim.fs.joinpath(folder, "metadata-only.jsonl"), "w")
            assert.is_not_nil(session_file)
            if not session_file then
                error("failed to create session file")
            end
            session_file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "Metadata only",
                    timestamp = 1704067200,
                    provider_name = "test",
                },
            }))
            session_file:close()
            local metadata_file = assert.not_nil(
                io.open(vim.fs.joinpath(folder, "metadata-only.meta.json"), "w")
            )
            assert.is_not_nil(metadata_file)
            metadata_file:write(vim.json.encode({
                session_id = "metadata-only",
                title = "Metadata only",
                created_at = 1704067200,
                updated_at = 1704153600,
                message_count = 42,
            }))
            metadata_file:close()

            local load_sync_stub = spy.stub(ChatHistory, "load_sync")
            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            vim.wait(1000, function()
                return sessions ~= nil
            end)

            assert.is_not_nil(sessions)
            --- @cast sessions agentic.ui.ChatHistory.SessionMeta[]
            assert.equal(1, #sessions)
            local session = assert.not_nil(sessions[1])
            assert.equal("metadata-only", session.session_id)
            assert.equal("Metadata only", session.title)
            assert.equal(42, session.message_count)
            assert.spy(load_sync_stub).was.called(0)
            load_sync_stub:revert()
        end)

        it("does not list metadata without a paired JSONL session", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local metadata_file = assert.not_nil(
                io.open(vim.fs.joinpath(folder, "orphan.meta.json"), "w")
            )
            metadata_file:write(vim.json.encode({
                session_id = "orphan",
                title = "Orphan",
                created_at = 1704067200,
                updated_at = 1704153600,
            }))
            metadata_file:close()

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            vim.wait(1000, function()
                return sessions ~= nil
            end)

            assert.is_not_nil(sessions)
            assert.equal(0, #sessions)
        end)

        it("lists split sessions without opening message JSONL", function()
            local history = ChatHistory:new()
            history.session_id = "metadata-file"
            history.title = "Metadata file"
            history:add_message({
                type = "user",
                text = "message",
                timestamp = 1704067200,
                provider_name = "test-provider",
            })
            history:save(function() end)

            local readfile_spy = spy.on(vim.fn, "readfile")
            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            readfile_spy:revert()

            assert.is_not_nil(sessions)
            assert.equal(1, #sessions)
            local read_paths = {}
            for _, call in ipairs(readfile_spy.calls) do
                read_paths[call[1]] = true
            end
            assert.is_true(
                read_paths[ChatHistory.get_metadata_file_path("metadata-file")]
            )
            assert.is_nil(
                read_paths[ChatHistory.get_jsonl_file_path("metadata-file")]
            )
        end)

        it(
            "lists sessions with malformed JSONL when sidecar metadata is valid",
            function()
                local folder = ChatHistory.get_sessions_folder()
                vim.fn.mkdir(folder, "p")
                local session_file = assert.not_nil(
                    io.open(vim.fs.joinpath(folder, "malformed.jsonl"), "w")
                )
                session_file:write("{not valid")
                session_file:close()
                local metadata_file = assert.not_nil(
                    io.open(vim.fs.joinpath(folder, "malformed.meta.json"), "w")
                )
                metadata_file:write(vim.json.encode({
                    session_id = "malformed",
                    title = "Malformed events",
                    created_at = 1,
                    updated_at = 2,
                }))
                metadata_file:close()

                local sessions = nil
                ChatHistory.list_sessions(function(result)
                    sessions = result
                end)
                vim.wait(1000, function()
                    return sessions ~= nil
                end)

                local listed_sessions = assert.not_nil(sessions)
                assert.equal(1, #listed_sessions)
                local listed_session = assert.not_nil(listed_sessions[1])
                assert.equal("malformed", listed_session.session_id)
            end
        )

        it("lists sessions synchronously", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local session_file =
                io.open(vim.fs.joinpath(folder, "async.jsonl"), "w")
            assert.is_not_nil(session_file)
            if not session_file then
                error("failed to create session file")
            end
            session_file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "Async",
                    timestamp = 1704067200,
                    provider_name = "test",
                },
            }))
            session_file:close()
            local metadata_file = assert.not_nil(
                io.open(vim.fs.joinpath(folder, "async.meta.json"), "w")
            )
            assert.is_not_nil(metadata_file)
            metadata_file:write(vim.json.encode({
                session_id = "async",
                title = "Async",
                created_at = 1704067200,
                updated_at = 1704153600,
            }))
            metadata_file:close()

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)

            assert.is_not_nil(sessions)
        end)

        it(
            "resolves the sessions folder once while listing candidates",
            function()
                save_session("folder-call-1", "First", 1)
                save_session("folder-call-2", "Second", 2)
                save_session("folder-call-3", "Third", 3)

                local get_sessions_folder_spy =
                    spy.on(ChatHistory, "get_sessions_folder")
                local sessions = nil
                ChatHistory.list_sessions(function(result)
                    sessions = result
                end)
                get_sessions_folder_spy:revert()

                assert.is_not_nil(sessions)
                assert.equal(3, #sessions)
                assert.equal(1, get_sessions_folder_spy.call_count)
            end
        )

        it("omits mixed JSONL without a valid sidecar", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local session_file =
                io.open(vim.fs.joinpath(folder, "newest-meta.jsonl"), "w")
            assert.is_not_nil(session_file)
            if not session_file then
                error("failed to create session file")
            end
            session_file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "agent",
                    text = "not listed",
                    provider_name = "test-provider",
                },
            }))
            session_file:close()

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            vim.wait(1000, function()
                return sessions ~= nil
            end)

            assert.equal(0, #sessions)
        end)

        it(
            "retries a failed replay flush without duplicating queued records",
            function()
                local source_id = "replay-source"
                vim.fn.mkdir(ChatHistory.get_sessions_folder(), "p")
                local source_path = ChatHistory.get_jsonl_file_path(source_id)
                local source = assert.not_nil(io.open(source_path, "w"))
                source:write(vim.json.encode({
                    type = "message",
                    message = { type = "user", text = "hello" },
                }) .. "\n")
                source:write(vim.json.encode({
                    type = "message",
                    message = { type = "agent", text = "world" },
                }) .. "\n")
                source:close()

                local history = ChatHistory:new()
                history.session_id = "replay-destination"
                local original_append = history._append_record
                local append = spy.stub(history, "_append_record")
                append:invokes(function(self, record)
                    if record.message and record.message.type == "agent" then
                        return false, "write failed"
                    end
                    return original_append(self, record)
                end)
                --- @type agentic.ui.ChatHistory.ReplaySource
                local source_spec = { kind = "jsonl", session_id = source_id }
                local ok = history:append_replay_source(source_spec)
                assert.is_false(ok)
                append:revert()

                ok = history:append_replay_source(source_spec)
                assert.is_true(ok)
                assert.equal(0, #history._pending_records)
                local records = vim.fn.readfile(
                    ChatHistory.get_jsonl_file_path("replay-destination")
                )
                assert.equal(2, #records)
                assert.equal("user", vim.json.decode(records[1]).message.type)
                assert.equal("agent", vim.json.decode(records[2]).message.type)
            end
        )

        it("writes queued event records before metadata", function()
            local history = ChatHistory:new()
            history.session_id = "metadata-order"
            history.has_user_message = true
            table.insert(history._pending_records, {
                type = "message",
                message = { type = "user", text = "hello" },
            })
            local calls = {}
            local append = spy.stub(history, "_append_record")
            local meta = spy.stub(history, "_write_meta_record")
            append:invokes(function()
                table.insert(calls, "event")
                return true, nil
            end)
            meta:invokes(function()
                table.insert(calls, "metadata")
                return true, nil
            end)
            history:save(function() end)
            append:revert()
            meta:revert()
            assert.same(calls, { "event", "metadata" })
        end)

        it("ignores legacy split files at runtime", function()
            local folder = ChatHistory.get_sessions_folder()
            vim.fn.mkdir(folder, "p")
            local legacy_file =
                io.open(vim.fs.joinpath(folder, "legacy.json"), "w")
            assert.is_not_nil(legacy_file)
            if not legacy_file then
                error("failed to create legacy file")
            end
            legacy_file:write(vim.json.encode({
                session_id = "legacy",
                title = "Legacy",
                timestamp = 1704067200,
                messages = {},
            }))
            legacy_file:close()

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)
            vim.wait(1000, function()
                return sessions ~= nil
            end)

            assert.is_not_nil(sessions)
            --- @cast sessions agentic.ui.ChatHistory.SessionMeta[]
            assert.equal(0, #sessions)
        end)

        it("deletes both paired session files", function()
            save_session("delete-me", "Delete me", 1704067200)
            local path = ChatHistory.get_jsonl_file_path("delete-me")
            local metadata_path =
                ChatHistory.get_metadata_file_path("delete-me")
            assert.is_not_nil(vim.uv.fs_stat(path))
            assert.is_not_nil(vim.uv.fs_stat(metadata_path))

            --- @type string|nil
            local delete_err = "not-called"
            ChatHistory.delete_session("delete-me", function(err)
                delete_err = err
            end)

            assert.is_nil(delete_err)
            assert.is_nil(vim.uv.fs_stat(path))
            assert.is_nil(vim.uv.fs_stat(metadata_path))
        end)

        it(
            "deletes a session when one paired file is already missing",
            function()
                save_session("delete-one", "Delete one", 1704067200)
                os.remove(ChatHistory.get_metadata_file_path("delete-one"))

                --- @type string|nil
                local delete_err = "not-called"
                ChatHistory.delete_session("delete-one", function(err)
                    delete_err = err
                end)

                assert.is_nil(delete_err)
                assert.is_nil(
                    vim.uv.fs_stat(
                        ChatHistory.get_jsonl_file_path("delete-one")
                    )
                )
            end
        )
    end)
end)
