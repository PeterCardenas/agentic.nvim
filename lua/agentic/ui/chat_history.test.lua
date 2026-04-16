--- @diagnostic disable: need-check-nil
local assert = require("tests.helpers.assert")
local spy = require("tests.helpers.spy")

local TEST_CWD = "/test/project"

describe("ChatHistory", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory
    --- @type agentic.utils.FileSystem
    local FileSystem
    local original_storage_path
    --- @type TestStub|nil
    local cwd_stub
    --- @type TestStub
    local mkdirp_stub
    --- @type TestStub
    local write_file_stub
    --- @type TestStub
    local read_file_stub
    --- @type table<string, string>
    local mock_files

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil

        mock_files = {}

        FileSystem = require("agentic.utils.file_system")

        mkdirp_stub = spy.stub(FileSystem, "mkdirp")
        mkdirp_stub:returns(true)

        write_file_stub = spy.stub(FileSystem, "write_file")
        write_file_stub:invokes(function(path, content, callback)
            mock_files[path] = content
            callback(nil)
        end)

        read_file_stub = spy.stub(FileSystem, "read_file")
        read_file_stub:invokes(function(path, _, _, callback)
            callback(mock_files[path])
        end)

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = "/test/storage"

        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        if cwd_stub then
            cwd_stub:revert()
            cwd_stub = nil
        end
        mkdirp_stub:revert()
        write_file_stub:revert()
        read_file_stub:revert()
        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.ui.chat_history"] = nil
    end)

    --- @param path string|nil
    local function stub_cwd(path)
        if cwd_stub then
            cwd_stub:revert()
        end
        cwd_stub = spy.stub(vim.uv, "cwd")
        cwd_stub:returns(path or TEST_CWD)
    end

    describe("get_project_folder", function()
        it("normalizes paths and appends hash suffix", function()
            local test_cases = {
                {
                    path = "/Users/me/projects/myapp",
                    pattern = "Users_me_projects_myapp",
                },
                {
                    path = "/Users/my user/my projects",
                    pattern = "my_user.*my_projects",
                },
                {
                    path = "C:\\Users\\me\\projects",
                    pattern = "C_.*Users_me_projects",
                },
            }

            for _, tc in ipairs(test_cases) do
                stub_cwd(tc.path)
                local folder = ChatHistory.get_project_folder()

                assert.truthy(folder:match(tc.pattern))
                assert.is_nil(folder:match("^_"))

                local hash = folder:match("_(%x+)$")
                assert.is_not_nil(hash)
                assert.equal(8, #hash)
            end
        end)

        it("produces unique hashes for different paths", function()
            stub_cwd("/path/one")
            local folder1 = ChatHistory.get_project_folder()

            stub_cwd("/path/two")
            local folder2 = ChatHistory.get_project_folder()

            assert.are_not.equal(folder1, folder2)
        end)
    end)

    describe("get_file_path", function()
        it(
            "combines storage_path, project_folder, and session_id.json",
            function()
                stub_cwd()
                local path = ChatHistory.get_file_path("session-abc")
                local project_folder = ChatHistory.get_project_folder()

                assert.truthy(path:match("^" .. vim.pesc("/test/storage")))
                assert.truthy(path:find(project_folder, 1, true))
                assert.truthy(path:match("session%-abc%.json$"))
            end
        )
    end)

    describe("message operations", function()
        it("add_message preserves insertion order", function()
            local history = ChatHistory:new()

            history:add_message({
                type = "user",
                text = "First",
                timestamp = os.time(),
                provider_name = "test-provider",
            })
            history:add_message({
                type = "agent",
                text = "Second",
                provider_name = "test-provider",
            })

            assert.equal(2, #history.messages)
            assert.equal("user", history.messages[1].type)
            assert.equal("agent", history.messages[2].type)
        end)

        describe("append_agent_text", function()
            it("creates new or appends based on last message type", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Hello",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello", history.messages[1].text)

                history:append_agent_text({
                    type = "agent",
                    text = " World",
                    provider_name = "test-provider",
                })
                assert.equal(1, #history.messages)
                assert.equal("Hello World", history.messages[1].text)

                history:add_message({
                    type = "user",
                    text = "Hi",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                assert.equal(3, #history.messages)
                assert.equal("agent", history.messages[3].type)
            end)

            it("treats agent and thought as separate types", function()
                local history = ChatHistory:new()

                history:append_agent_text({
                    type = "agent",
                    text = "Response",
                    provider_name = "test-provider",
                })
                history:append_agent_text({
                    type = "thought",
                    text = "Thinking...",
                    provider_name = "test-provider",
                })

                assert.equal(2, #history.messages)
                assert.equal("agent", history.messages[1].type)
                assert.equal("thought", history.messages[2].type)
            end)
        end)

        describe("update_tool_call", function()
            it("finds and merges tool_call by ID", function()
                local history = ChatHistory:new()

                history:add_message({
                    type = "tool_call",
                    tool_call_id = "tc-123",
                    status = "pending",
                    kind = "read",
                })

                history:update_tool_call("tc-123", {
                    tool_call_id = "tc-123",
                    status = "completed",
                    body = { "content" },
                    type = "tool_call",
                })

                assert.equal("completed", history.messages[1].status)
                assert.is_not_nil(history.messages[1].body)
            end)

            it("does nothing if tool_call not found", function()
                local history = ChatHistory:new()
                history:add_message({
                    type = "user",
                    text = "Hello",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })

                history:update_tool_call(
                    "non-existent",
                    { status = "completed", type = "tool_call" }
                )

                assert.equal(1, #history.messages)
                assert.equal("user", history.messages[1].type)
            end)
        end)
    end)

    describe("save and load", function()
        before_each(function()
            stub_cwd()
        end)

        it("persists and restores ChatHistory instance", function()
            local original = ChatHistory:new()
            original.session_id = "roundtrip-test"
            original:add_message({
                type = "user",
                text = "Test message",
                timestamp = os.time(),
                provider_name = "test-provider",
            })

            local save_done = false
            local save_err = nil
            original:save(function(err)
                save_err = err
                save_done = true
            end)

            vim.wait(1000, function()
                return save_done
            end)
            assert.is_nil(save_err)

            local path = ChatHistory.get_file_path(original.session_id)
            assert.equal(1, mkdirp_stub.call_count)
            assert.equal(1, write_file_stub.call_count)

            local saved_content = mock_files[path]
            assert.is_not_nil(saved_content)

            local parsed = vim.json.decode(saved_content)
            assert.equal(original.session_id, parsed.session_id)
            assert.equal("Test message", parsed.title)
            assert.is_not_nil(parsed.timestamp)

            local loaded = nil
            local load_err = nil
            local load_done = false
            ChatHistory.load(original.session_id, function(history, err)
                loaded = history
                load_err = err
                load_done = true
            end)

            vim.wait(1000, function()
                return load_done
            end)

            assert.is_nil(load_err)
            assert.is_not_nil(loaded)
            --- @cast loaded agentic.ui.ChatHistory
            assert.equal(original.session_id, loaded.session_id)
            assert.equal(original.timestamp, loaded.timestamp)
            assert.equal(1, #loaded.messages)
            assert.equal("Test message", loaded.messages[1].text)
        end)

        it("returns error for missing or corrupted files", function()
            local test_cases = {
                { session_id = "non-existent" },
                {
                    session_id = "corrupted",
                    content = "not valid json {{{",
                },
            }

            for _, tc in ipairs(test_cases) do
                if tc.content then
                    local path = ChatHistory.get_file_path(tc.session_id)
                    mock_files[path] = tc.content
                end

                local loaded = nil
                local load_err = nil
                local done = false

                ChatHistory.load(tc.session_id, function(history, err)
                    loaded = history
                    load_err = err
                    done = true
                end)

                vim.wait(1000, function()
                    return done
                end)

                assert.is_nil(loaded)
                assert.is_not_nil(load_err)
            end
        end)
    end)

    describe("delete_session", function()
        local temp_dir
        local original_delete_storage

        before_each(function()
            stub_cwd()
            temp_dir = vim.fn.tempname()
            vim.fn.mkdir(temp_dir, "p")
            local Config = require("agentic.config")
            original_delete_storage = Config.session_restore.storage_path
            Config.session_restore.storage_path = temp_dir
        end)

        after_each(function()
            vim.fn.delete(temp_dir, "rf")
            local Config = require("agentic.config")
            Config.session_restore.storage_path = original_delete_storage
        end)

        local function create_session_file(session_id)
            local file_path = ChatHistory.get_file_path(session_id)
            local dir = vim.fn.fnamemodify(file_path, ":h")
            vim.fn.mkdir(dir, "p")
            local f = io.open(file_path, "w")
            assert.is_not_nil(f)
            if not f then
                error("failed to create session file")
            end
            f:write(vim.json.encode({
                session_id = session_id,
                title = "Test " .. session_id,
                timestamp = os.time(),
                messages = {},
            }))
            f:close()
            return file_path
        end

        it("deletes session file and calls callback with nil", function()
            local file_path = create_session_file("delete-me")
            assert.is_not_nil(vim.uv.fs_stat(file_path))

            --- @type string|nil
            local result_err = "not-called"
            ChatHistory.delete_session("delete-me", function(err)
                result_err = err
            end)

            assert.is_nil(result_err)
            assert.is_nil(vim.uv.fs_stat(file_path))
        end)

        it("calls callback with error when file does not exist", function()
            local result_err = nil
            ChatHistory.delete_session("nonexistent", function(err)
                result_err = err
            end)

            assert.is_not_nil(result_err)
        end)

        it("works without callback", function()
            assert.has_no_errors(function()
                ChatHistory.delete_session("nonexistent")
            end)
        end)

        it("works without callback on existing file", function()
            create_session_file("no-callback")

            assert.has_no_errors(function()
                ChatHistory.delete_session("no-callback")
            end)

            local path = ChatHistory.get_file_path("no-callback")
            assert.is_nil(vim.uv.fs_stat(path))
        end)

        it("only deletes the specified session file", function()
            local keep_path = create_session_file("session-keep")
            local delete_path = create_session_file("session-delete")

            ChatHistory.delete_session("session-delete", function(_err) end)

            assert.is_not_nil(vim.uv.fs_stat(keep_path))
            assert.is_nil(vim.uv.fs_stat(delete_path))
        end)

        it("deleted session no longer appears in list_sessions", function()
            create_session_file("session-a")
            create_session_file("session-b")

            ChatHistory.delete_session("session-a", function(_err) end)

            local sessions = nil
            ChatHistory.list_sessions(function(result)
                sessions = result
            end)

            assert.is_not_nil(sessions)
            --- @cast sessions agentic.ui.ChatHistory.SessionMeta[]
            assert.equal(1, #sessions)
            assert.equal("session-b", sessions[1].session_id)
        end)

        it("returns error on double deletion", function()
            create_session_file("double-delete")

            --- @type string|nil
            local first_err = "not-called"
            ChatHistory.delete_session("double-delete", function(err)
                first_err = err
            end)
            assert.is_nil(first_err)

            local second_err = nil
            ChatHistory.delete_session("double-delete", function(err)
                second_err = err
            end)
            assert.is_not_nil(second_err)
        end)
    end)

    describe("list_sessions", function()
        before_each(function()
            stub_cwd()
        end)

        it("returns empty array when no sessions exist", function()
            local sessions = nil
            local done = false

            ChatHistory.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(0, #sessions)
        end)

        it("returns all saved sessions in project folder", function()
            local session_ids = { "session-1", "session-2" }

            for _, id in ipairs(session_ids) do
                local s = ChatHistory:new()
                s.session_id = id
                s:add_message({
                    type = "user",
                    text = id .. " message",
                    timestamp = os.time(),
                    provider_name = "test-provider",
                })

                local saved = false
                s:save(function()
                    saved = true
                end)
                vim.wait(1000, function()
                    return saved
                end)
            end

            local sessions = nil
            local done = false

            ChatHistory.list_sessions(function(result)
                sessions = result
                done = true
            end)

            vim.wait(1000, function()
                return done
            end)

            assert.equal(2, #sessions)

            local ids = {}
            for _, s in ipairs(sessions or {}) do
                ids[s.session_id] = true
            end
            assert.is_true(ids["session-1"])
            assert.is_true(ids["session-2"])
        end)
    end)
end)
