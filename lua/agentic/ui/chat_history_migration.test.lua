local assert = require("tests.helpers.assert")

describe("ChatHistory migration", function()
    --- @type agentic.ui.ChatHistory
    local ChatHistory
    local temp_dir
    local original_storage_path

    before_each(function()
        package.loaded["agentic.ui.chat_history"] = nil
        package.loaded["agentic.utils.file_system"] = nil

        temp_dir = vim.fn.tempname()
        vim.fn.mkdir(temp_dir, "p")

        local Config = require("agentic.config")
        original_storage_path = Config.session_restore.storage_path
        Config.session_restore.storage_path = temp_dir

        ChatHistory = require("agentic.ui.chat_history")
    end)

    after_each(function()
        vim.fn.delete(temp_dir, "rf")

        local Config = require("agentic.config")
        Config.session_restore.storage_path = original_storage_path
        package.loaded["agentic.ui.chat_history"] = nil
        package.loaded["agentic.utils.file_system"] = nil
    end)

    it(
        "splits mixed JSONL atomically while preserving event order and backup",
        function()
            local project_dir = vim.fs.joinpath(temp_dir, "project-mixed")
            vim.fn.mkdir(project_dir, "p")
            local jsonl_path = vim.fs.joinpath(project_dir, "mixed-1.jsonl")
            local records = {
                {
                    type = "meta",
                    session_id = "mixed-1",
                    title = "Mixed title",
                    created_at = 1704067200,
                    updated_at = 1704067201,
                    message_count = 1,
                },
                {
                    type = "message",
                    message = {
                        type = "tool_call",
                        tool_call_id = "tool-1",
                        status = "pending",
                        body = { "one", "two" },
                    },
                },
                {
                    type = "tool_call_update",
                    tool_call_id = "tool-1",
                    update = {
                        type = "tool_call",
                        tool_call_id = "tool-1",
                        status = "completed",
                        body = { "one", "two", "three" },
                    },
                },
            }
            local file = io.open(jsonl_path, "w")
            assert.is_not_nil(file)
            if not file then
                error("failed to create mixed JSONL")
            end
            for _, record in ipairs(records) do
                file:write(vim.json.encode(record), "\n")
            end
            file:close()

            local result = ChatHistory.migrate_all_sessions_to_split()

            assert.equal(1, result.migrated)
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(project_dir, "mixed-1.meta.json")
                )
            )
            assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
            local metadata = vim.json.decode(
                table.concat(
                    vim.fn.readfile(
                        vim.fs.joinpath(project_dir, "mixed-1.meta.json")
                    ),
                    "\n"
                )
            )
            assert.equal("Mixed title", metadata.title)
            local migrated_lines = vim.fn.readfile(jsonl_path)
            assert.equal(2, #migrated_lines)
            assert.equal("message", vim.json.decode(migrated_lines[1]).type)
            assert.equal(
                "tool_call_update",
                vim.json.decode(migrated_lines[2]).type
            )
            assert.equal(3, #vim.json.decode(migrated_lines[2]).update.body)
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-mixed",
                        "mixed-1.jsonl"
                    )
                )
            )
        end
    )

    it("leaves split sessions unchanged on a second migration", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-idempotent")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "split-1.jsonl")
        local metadata_path = vim.fs.joinpath(project_dir, "split-1.meta.json")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create split JSONL")
        end
        jsonl_file:write(vim.json.encode({
            type = "message",
            message = {
                type = "user",
                text = "retained",
                timestamp = 1704067200,
                provider_name = "test",
            },
        }))
        jsonl_file:close()
        local metadata_file = io.open(metadata_path, "w")
        assert.is_not_nil(metadata_file)
        if not metadata_file then
            error("failed to create split metadata")
        end
        metadata_file:write(vim.json.encode({
            session_id = "split-1",
            title = "Split",
            created_at = 1704067200,
            updated_at = 1704067200,
            message_count = 1,
        }))
        metadata_file:close()

        local result = ChatHistory.migrate_all_sessions_to_split()

        assert.equal(0, result.migrated)
        assert.equal(1, result.skipped)
        assert.equal(
            "retained",
            vim.json.decode(vim.fn.readfile(jsonl_path)[1]).message.text
        )
    end)

    it(
        "preserves valid external metadata while splitting mixed JSONL",
        function()
            local project_dir =
                vim.fs.joinpath(temp_dir, "project-meta-precedence")
            vim.fn.mkdir(project_dir, "p")
            local jsonl_path = vim.fs.joinpath(project_dir, "precedence.jsonl")
            local metadata_path =
                vim.fs.joinpath(project_dir, "precedence.meta.json")
            local jsonl_file = assert.not_nil(io.open(jsonl_path, "w"))
            jsonl_file:write(vim.json.encode({
                type = "meta",
                session_id = "precedence",
                title = "Embedded title",
                created_at = 1,
                updated_at = 2,
            }))
            jsonl_file:write("\n")
            jsonl_file:write(vim.json.encode({
                type = "message",
                message = {
                    type = "user",
                    text = "retained",
                    timestamp = 2,
                    provider_name = "test",
                },
            }))
            jsonl_file:close()

            local metadata_file = assert.not_nil(io.open(metadata_path, "w"))
            metadata_file:write(vim.json.encode({
                session_id = "precedence",
                title = "External title",
                created_at = 3,
                updated_at = 4,
                message_count = 1,
            }))
            metadata_file:close()

            local result = ChatHistory.migrate_all_sessions_to_split()

            assert.equal(1, result.migrated)
            assert.equal(
                "External title",
                vim.json.decode(
                    table.concat(vim.fn.readfile(metadata_path), "\n")
                ).title
            )
            local lines = vim.fn.readfile(jsonl_path)
            assert.equal(1, #lines)
            assert.equal("message", vim.json.decode(lines[1]).type)
        end
    )

    it("backs up and migrates legacy monolithic sessions", function()
        local legacy_dir = vim.fs.joinpath(temp_dir, "project-a")
        vim.fn.mkdir(legacy_dir, "p")
        local legacy_path = vim.fs.joinpath(legacy_dir, "legacy-1.json")

        local legacy_payload = {
            session_id = "legacy-1",
            title = "Legacy title",
            timestamp = 1704067200,
            messages = {
                {
                    type = "user",
                    text = "Legacy message",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }

        local legacy_file = io.open(legacy_path, "w")
        assert.is_not_nil(legacy_file)
        if not legacy_file then
            error("failed to create legacy session")
        end
        legacy_file:write(vim.json.encode(legacy_payload))
        legacy_file:close()

        local result = ChatHistory.migrate_all_legacy_sessions()
        assert.is_not_nil(result)
        --- @cast result agentic.ui.ChatHistory.MigrationResult
        assert.is_not_nil(vim.uv.fs_stat(result.backup_dir))

        local backup_path =
            vim.fs.joinpath(result.backup_dir, "project-a", "legacy-1.json")
        assert.is_not_nil(vim.uv.fs_stat(backup_path))
        assert.is_nil(vim.uv.fs_stat(legacy_path))

        local migrated_jsonl =
            vim.fn.readfile(vim.fs.joinpath(legacy_dir, "legacy-1.jsonl"))
        local backup_content = vim.fn.readfile(backup_path)

        local parsed_metadata = vim.json.decode(migrated_jsonl[1])
        local parsed_message = vim.json.decode(migrated_jsonl[2])
        local parsed_backup =
            vim.json.decode(table.concat(backup_content, "\n"))

        assert.equal("message", parsed_message.type)
        local first_message = assert.not_nil(parsed_message.message)
        assert.equal("Legacy message", first_message.text)
        assert.equal("legacy-1", parsed_metadata.session_id)
        assert.equal("Legacy title", parsed_metadata.title)
        assert.equal(1704067200, parsed_metadata.created_at)
        assert.equal(1704067200, parsed_metadata.updated_at)
        assert.equal("legacy-1", parsed_backup.session_id)
        assert.equal("Legacy title", parsed_backup.title)
    end)

    it(
        "migrates split sessions to JSONL with backups and removes active split files",
        function()
            local project_dir = vim.fs.joinpath(temp_dir, "project-split")
            vim.fn.mkdir(project_dir, "p")
            local messages_path = vim.fs.joinpath(project_dir, "split-1.json")
            local metadata_path =
                vim.fs.joinpath(project_dir, "split-1.meta.json")
            local jsonl_path = vim.fs.joinpath(project_dir, "split-1.jsonl")

            local messages_file = io.open(messages_path, "w")
            assert.is_not_nil(messages_file)
            if not messages_file then
                error("failed to create split messages")
            end
            messages_file:write(vim.json.encode({
                messages = {
                    {
                        type = "user",
                        text = "Split message",
                        timestamp = 1704067201,
                        provider_name = "test-provider",
                    },
                },
            }))
            messages_file:close()

            local metadata_file = io.open(metadata_path, "w")
            assert.is_not_nil(metadata_file)
            if not metadata_file then
                error("failed to create split metadata")
            end
            metadata_file:write(vim.json.encode({
                session_id = "split-1",
                title = "Split title",
                created_at = 1704067200,
                updated_at = 1704067202,
            }))
            metadata_file:close()

            local result = ChatHistory.migrate_all_sessions_to_jsonl()

            assert.equal(1, result.migrated)
            assert.equal(0, result.failed)
            assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
            assert.is_nil(vim.uv.fs_stat(messages_path))
            assert.is_nil(vim.uv.fs_stat(metadata_path))
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-split",
                        "split-1.json"
                    )
                )
            )
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-split",
                        "split-1.meta.json"
                    )
                )
            )

            local lines = vim.fn.readfile(jsonl_path)
            assert.equal("meta", vim.json.decode(lines[1]).type)
            local message_record = vim.json.decode(lines[2])
            assert.equal("message", message_record.type)
            assert.equal("Split message", message_record.message.text)
        end
    )

    it("is idempotent for sessions already stored as JSONL", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-jsonl")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "session-1.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create jsonl session")
        end
        jsonl_file:write(vim.json.encode({
            type = "meta",
            session_id = "session-1",
            title = "Already JSONL",
            created_at = 1704067200,
            updated_at = 1704067200,
        }))
        jsonl_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(0, result.migrated)
        assert.equal(1, result.skipped)
        assert.equal(0, result.failed)
        assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
    end)

    it("rejects JSONL with incomplete metadata", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-incomplete-meta")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "incomplete.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create incomplete JSONL")
        end
        jsonl_file:write(vim.json.encode({ type = "meta" }))
        jsonl_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(0, result.skipped)
        assert.equal(1, result.failed)
        assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
    end)

    it("rejects split sessions with non-list messages", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-keyed-messages")
        vim.fn.mkdir(project_dir, "p")
        local messages_path = vim.fs.joinpath(project_dir, "keyed.json")
        local metadata_path = vim.fs.joinpath(project_dir, "keyed.meta.json")
        local jsonl_path = vim.fs.joinpath(project_dir, "keyed.jsonl")

        local messages_file = io.open(messages_path, "w")
        assert.is_not_nil(messages_file)
        if not messages_file then
            error("failed to create keyed messages")
        end
        messages_file:write(vim.json.encode({
            messages = {
                retained = {
                    type = "user",
                    text = "Must not be discarded",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        messages_file:close()

        local metadata_file = io.open(metadata_path, "w")
        assert.is_not_nil(metadata_file)
        if not metadata_file then
            error("failed to create keyed metadata")
        end
        metadata_file:write(vim.json.encode({
            session_id = "keyed",
            created_at = 1704067200,
            updated_at = 1704067200,
        }))
        metadata_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(0, result.migrated)
        assert.equal(1, result.failed)
        assert.is_nil(vim.uv.fs_stat(jsonl_path))
    end)

    it("prefers an active legacy JSON source for malformed JSONL", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-active-source")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "active.jsonl")
        local legacy_path = vim.fs.joinpath(project_dir, "active.json")

        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create malformed JSONL")
        end
        jsonl_file:write("{malformed")
        jsonl_file:close()

        local legacy_file = io.open(legacy_path, "w")
        assert.is_not_nil(legacy_file)
        if not legacy_file then
            error("failed to create active legacy source")
        end
        legacy_file:write(vim.json.encode({
            session_id = "active",
            title = "Active source",
            created_at = 1704067200,
            updated_at = 1704067201,
            messages = {
                {
                    type = "user",
                    text = "Recovered from active source",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        legacy_file:close()

        local original_fs_dir = vim.fs.dir
        vim.fs.dir = function(path, ...)
            if path == project_dir then
                local entries = {
                    { "active.jsonl", "file" },
                    { "active.json", "file" },
                }
                local index = 0
                return function()
                    index = index + 1
                    local entry = entries[index]
                    if entry then
                        return entry[1], entry[2]
                    end
                end
            end
            return original_fs_dir(path, ...)
        end
        local result = ChatHistory.migrate_all_sessions_to_jsonl()
        vim.fs.dir = original_fs_dir

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.is_nil(vim.uv.fs_stat(legacy_path))
        assert.equal(
            "Recovered from active source",
            vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
        )
    end)

    it("recovers malformed JSONL from a preserved legacy backup", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-recovery")
        local backup_root = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105200",
            "project-recovery"
        )
        vim.fn.mkdir(project_dir, "p")
        vim.fn.mkdir(backup_root, "p")

        local jsonl_path = vim.fs.joinpath(project_dir, "recovered-1.jsonl")
        local malformed_file = io.open(jsonl_path, "w")
        assert.is_not_nil(malformed_file)
        if not malformed_file then
            error("failed to create malformed JSONL")
        end
        malformed_file:write('{"type":"meta"}\n{not valid')
        malformed_file:close()

        local backup_path = vim.fs.joinpath(backup_root, "recovered-1.json")
        local backup_file = io.open(backup_path, "w")
        assert.is_not_nil(backup_file)
        if not backup_file then
            error("failed to create legacy backup")
        end
        backup_file:write(vim.json.encode({
            session_id = "recovered-1",
            title = "Recovered title",
            created_at = 1704067200,
            updated_at = 1704067201,
            messages = {
                {
                    type = "user",
                    text = "Recovered message",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        backup_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
        assert.is_not_nil(
            vim.uv.fs_stat(
                vim.fs.joinpath(
                    result.backup_dir,
                    "project-recovery",
                    "recovered-1.jsonl"
                )
            )
        )
        local lines = vim.fn.readfile(jsonl_path)
        assert.equal("meta", vim.json.decode(lines[1]).type)
        assert.equal(
            "Recovered message",
            vim.json.decode(lines[2]).message.text
        )
        assert.is_not_nil(vim.uv.fs_stat(backup_path))
    end)

    it("recovers JSONL from a messages-only preserved backup", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-messages-only")
        local backup_dir = vim.fs.joinpath(
            temp_dir,
            "_jsonl_migration_backups",
            "20260722_105200",
            "project-messages-only"
        )
        vim.fn.mkdir(project_dir, "p")
        vim.fn.mkdir(backup_dir, "p")

        local jsonl_path = vim.fs.joinpath(project_dir, "messages-only.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create corrupt JSONL")
        end
        jsonl_file:write('{"type":"message"}')
        jsonl_file:close()

        local backup_file =
            io.open(vim.fs.joinpath(backup_dir, "messages-only.json"), "w")
        assert.is_not_nil(backup_file)
        if not backup_file then
            error("failed to create messages-only backup")
        end
        backup_file:write(vim.json.encode({
            messages = {
                {
                    type = "user",
                    text = "Recovered messages-only",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        backup_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.equal(
            "Recovered messages-only",
            vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
        )
    end)

    it("recovers JSONL with unknown or incomplete records", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-invalid-jsonl")
        local backup_dir = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105200",
            "project-invalid-jsonl"
        )
        vim.fn.mkdir(project_dir, "p")
        vim.fn.mkdir(backup_dir, "p")

        local jsonl_path = vim.fs.joinpath(project_dir, "invalid.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create invalid JSONL")
        end
        jsonl_file:write('{"type":"message"}\n{"type":"unknown"}')
        jsonl_file:close()

        local backup_file =
            io.open(vim.fs.joinpath(backup_dir, "invalid.json"), "w")
        assert.is_not_nil(backup_file)
        if not backup_file then
            error("failed to create legacy backup")
        end
        backup_file:write(vim.json.encode({
            session_id = "invalid",
            messages = {
                {
                    type = "user",
                    text = "Recovered invalid JSONL",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        backup_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.equal(
            "Recovered invalid JSONL",
            vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
        )
    end)

    it("recovers an empty JSONL from a preserved legacy backup", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-empty-recovery")
        local backup_dir = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105200",
            "project-empty-recovery"
        )
        vim.fn.mkdir(project_dir, "p")
        vim.fn.mkdir(backup_dir, "p")

        local jsonl_path = vim.fs.joinpath(project_dir, "empty-recovered.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create empty JSONL")
        end
        jsonl_file:close()

        local backup_path = vim.fs.joinpath(backup_dir, "empty-recovered.json")
        local backup_file = io.open(backup_path, "w")
        assert.is_not_nil(backup_file)
        if not backup_file then
            error("failed to create legacy backup")
        end
        backup_file:write(vim.json.encode({
            session_id = "empty-recovered",
            messages = {
                {
                    type = "user",
                    text = "Recovered from empty JSONL",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        backup_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.equal(
            "Recovered from empty JSONL",
            vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
        )
    end)

    it("fails safely when a preserved backup has invalid messages", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-invalid-source")
        local backup_dir = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105200",
            "project-invalid-source"
        )
        vim.fn.mkdir(project_dir, "p")
        vim.fn.mkdir(backup_dir, "p")

        local jsonl_path = vim.fs.joinpath(project_dir, "invalid-backup.jsonl")
        local active_content = "{malformed active JSONL"
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create malformed JSONL")
        end
        jsonl_file:write(active_content)
        jsonl_file:close()

        local backup_file =
            io.open(vim.fs.joinpath(backup_dir, "invalid-backup.json"), "w")
        assert.is_not_nil(backup_file)
        if not backup_file then
            error("failed to create invalid legacy backup")
        end
        backup_file:write(vim.json.encode({
            session_id = "invalid-source",
            messages = "not a list",
        }))
        backup_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(0, result.recovered)
        assert.equal(1, result.failed)
        assert.equal(
            active_content,
            table.concat(vim.fn.readfile(jsonl_path), "\n")
        )
    end)

    it("skips a preserved backup containing non-table messages", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-invalid-list")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "fallback.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create malformed JSONL")
        end
        jsonl_file:write("{malformed")
        jsonl_file:close()

        local invalid_backup_dir = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105300",
            "project-invalid-list"
        )
        local valid_backup_dir = vim.fs.joinpath(
            temp_dir,
            "_legacy_backups",
            "20260722_105200",
            "project-invalid-list"
        )
        vim.fn.mkdir(invalid_backup_dir, "p")
        vim.fn.mkdir(valid_backup_dir, "p")

        local invalid_backup =
            io.open(vim.fs.joinpath(invalid_backup_dir, "fallback.json"), "w")
        assert.is_not_nil(invalid_backup)
        if not invalid_backup then
            error("failed to create invalid legacy backup")
        end
        invalid_backup:write(vim.json.encode({
            session_id = "fallback",
            messages = { "bad" },
        }))
        invalid_backup:close()

        local valid_backup =
            io.open(vim.fs.joinpath(valid_backup_dir, "fallback.json"), "w")
        assert.is_not_nil(valid_backup)
        if not valid_backup then
            error("failed to create valid legacy backup")
        end
        valid_backup:write(vim.json.encode({
            session_id = "fallback",
            title = "Fallback backup",
            messages = {
                {
                    type = "user",
                    text = "Recovered after invalid backup",
                    timestamp = 1704067201,
                    provider_name = "test-provider",
                },
            },
        }))
        valid_backup:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        assert.equal(0, result.failed)
        assert.equal(
            "Recovered after invalid backup",
            vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
        )
    end)

    it(
        "recovers whitespace-only JSONL from a preserved legacy backup",
        function()
            local project_dir =
                vim.fs.joinpath(temp_dir, "project-blank-recovery")
            local backup_dir = vim.fs.joinpath(
                temp_dir,
                "_legacy_backups",
                "20260722_105200",
                "project-blank-recovery"
            )
            vim.fn.mkdir(project_dir, "p")
            vim.fn.mkdir(backup_dir, "p")

            local jsonl_path =
                vim.fs.joinpath(project_dir, "blank-recovered.jsonl")
            local jsonl_file = io.open(jsonl_path, "w")
            assert.is_not_nil(jsonl_file)
            if not jsonl_file then
                error("failed to create blank JSONL")
            end
            jsonl_file:write(" \n\t\n")
            jsonl_file:close()

            local backup_path =
                vim.fs.joinpath(backup_dir, "blank-recovered.json")
            local backup_file = io.open(backup_path, "w")
            assert.is_not_nil(backup_file)
            if not backup_file then
                error("failed to create legacy backup")
            end
            backup_file:write(vim.json.encode({
                session_id = "blank-recovered",
                messages = {
                    {
                        type = "user",
                        text = "Recovered from blank JSONL",
                        timestamp = 1704067201,
                        provider_name = "test-provider",
                    },
                },
            }))
            backup_file:close()

            local result = ChatHistory.migrate_all_sessions_to_jsonl()

            assert.equal(1, result.recovered)
            assert.equal(0, result.failed)
            assert.equal(
                "Recovered from blank JSONL",
                vim.json.decode(vim.fn.readfile(jsonl_path)[2]).message.text
            )
        end
    )

    it("uses the newest valid preserved backup", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-newest-source")
        vim.fn.mkdir(project_dir, "p")
        local jsonl_path = vim.fs.joinpath(project_dir, "newest.jsonl")
        local jsonl_file = io.open(jsonl_path, "w")
        assert.is_not_nil(jsonl_file)
        if not jsonl_file then
            error("failed to create malformed JSONL")
        end
        jsonl_file:write("{malformed")
        jsonl_file:close()

        for timestamp, text in pairs({
            ["20260722_105200"] = "Older backup",
            ["20260722_105300"] = "Newest backup",
        }) do
            local backup_dir = vim.fs.joinpath(
                temp_dir,
                "_legacy_backups",
                timestamp,
                "project-newest-source"
            )
            vim.fn.mkdir(backup_dir, "p")
            local backup_file =
                io.open(vim.fs.joinpath(backup_dir, "newest.json"), "w")
            assert.is_not_nil(backup_file)
            if not backup_file then
                error("failed to create legacy backup")
            end
            backup_file:write(vim.json.encode({
                session_id = "newest",
                title = text,
                messages = {},
            }))
            backup_file:close()
        end

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.recovered)
        local metadata = vim.json.decode(vim.fn.readfile(jsonl_path)[1])
        assert.equal("Newest backup", metadata.title)
    end)

    it("migrates empty split legacy sessions as zero-message JSONL", function()
        local project_dir = vim.fs.joinpath(temp_dir, "project-empty")
        vim.fn.mkdir(project_dir, "p")
        local messages_path = vim.fs.joinpath(project_dir, "empty-1.json")
        local metadata_path = vim.fs.joinpath(project_dir, "empty-1.meta.json")
        local jsonl_path = vim.fs.joinpath(project_dir, "empty-1.jsonl")

        local messages_file = io.open(messages_path, "w")
        assert.is_not_nil(messages_file)
        if not messages_file then
            error("failed to create empty messages")
        end
        messages_file:close()

        local metadata_file = io.open(metadata_path, "w")
        assert.is_not_nil(metadata_file)
        if not metadata_file then
            error("failed to create empty metadata")
        end
        metadata_file:close()

        local result = ChatHistory.migrate_all_sessions_to_jsonl()

        assert.equal(1, result.migrated)
        assert.equal(0, result.failed)
        assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
        assert.is_nil(vim.uv.fs_stat(messages_path))
        assert.is_nil(vim.uv.fs_stat(metadata_path))
        assert.is_not_nil(
            vim.uv.fs_stat(
                vim.fs.joinpath(
                    result.backup_dir,
                    "project-empty",
                    "empty-1.json"
                )
            )
        )
        assert.is_not_nil(
            vim.uv.fs_stat(
                vim.fs.joinpath(
                    result.backup_dir,
                    "project-empty",
                    "empty-1.meta.json"
                )
            )
        )

        local lines = vim.fn.readfile(jsonl_path)
        assert.equal(1, #lines)
        local parsed_metadata = vim.json.decode(lines[1])
        assert.equal("meta", parsed_metadata.type)
        assert.equal("empty-1", parsed_metadata.session_id)
        assert.equal(0, parsed_metadata.message_count)
    end)

    it(
        "backs up and removes stale legacy files when JSONL already exists",
        function()
            local project_dir = vim.fs.joinpath(temp_dir, "project-stale")
            vim.fn.mkdir(project_dir, "p")
            local messages_path = vim.fs.joinpath(project_dir, "stale-1.json")
            local metadata_path =
                vim.fs.joinpath(project_dir, "stale-1.meta.json")
            local jsonl_path = vim.fs.joinpath(project_dir, "stale-1.jsonl")

            local messages_file = io.open(messages_path, "w")
            assert.is_not_nil(messages_file)
            if not messages_file then
                error("failed to create stale messages")
            end
            messages_file:write(vim.json.encode({ messages = {} }))
            messages_file:close()

            local metadata_file = io.open(metadata_path, "w")
            assert.is_not_nil(metadata_file)
            if not metadata_file then
                error("failed to create stale metadata")
            end
            metadata_file:write(vim.json.encode({ session_id = "stale-1" }))
            metadata_file:close()

            local jsonl_file = io.open(jsonl_path, "w")
            assert.is_not_nil(jsonl_file)
            if not jsonl_file then
                error("failed to create existing jsonl")
            end
            jsonl_file:write(vim.json.encode({
                type = "meta",
                session_id = "stale-1",
                title = "Already migrated",
                created_at = 1704067200,
                updated_at = 1704067200,
            }))
            jsonl_file:close()

            local result = ChatHistory.migrate_all_sessions_to_jsonl()

            assert.equal(1, result.migrated)
            assert.equal(1, result.skipped)
            assert.equal(0, result.failed)
            assert.is_not_nil(vim.uv.fs_stat(jsonl_path))
            assert.is_nil(vim.uv.fs_stat(messages_path))
            assert.is_nil(vim.uv.fs_stat(metadata_path))
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-stale",
                        "stale-1.json"
                    )
                )
            )
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-stale",
                        "stale-1.meta.json"
                    )
                )
            )
        end
    )

    it(
        "backs up and removes corrupt legacy files from the active project folder",
        function()
            local project_dir = vim.fs.joinpath(temp_dir, "project-corrupt")
            vim.fn.mkdir(project_dir, "p")
            local corrupt_path = vim.fs.joinpath(project_dir, "bad.json")
            local corrupt_metadata_path =
                vim.fs.joinpath(project_dir, "bad.meta.json")
            local corrupt_file = io.open(corrupt_path, "w")
            assert.is_not_nil(corrupt_file)
            if not corrupt_file then
                error("failed to create corrupt session")
            end
            corrupt_file:write("{not json")
            corrupt_file:close()

            local corrupt_metadata_file = io.open(corrupt_metadata_path, "w")
            assert.is_not_nil(corrupt_metadata_file)
            if not corrupt_metadata_file then
                error("failed to create corrupt metadata")
            end
            corrupt_metadata_file:write("{also not json")
            corrupt_metadata_file:close()

            local result = ChatHistory.migrate_all_sessions_to_jsonl()

            assert.equal(0, result.migrated)
            assert.equal(1, result.failed)
            assert.is_nil(vim.uv.fs_stat(corrupt_path))
            assert.is_nil(vim.uv.fs_stat(corrupt_metadata_path))
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-corrupt",
                        "bad.json"
                    )
                )
            )
            assert.is_not_nil(
                vim.uv.fs_stat(
                    vim.fs.joinpath(
                        result.backup_dir,
                        "project-corrupt",
                        "bad.meta.json"
                    )
                )
            )
            assert.is_nil(
                vim.uv.fs_stat(vim.fs.joinpath(project_dir, "bad.jsonl"))
            )
        end
    )
end)
