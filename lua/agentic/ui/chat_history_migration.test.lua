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

        local migrated_messages = vim.fn.readfile(legacy_path)
        local migrated_metadata =
            vim.fn.readfile(vim.fs.joinpath(legacy_dir, "legacy-1.meta.json"))
        local backup_content = vim.fn.readfile(backup_path)

        local parsed_messages =
            vim.json.decode(table.concat(migrated_messages, "\n"))
        local parsed_metadata =
            vim.json.decode(table.concat(migrated_metadata, "\n"))
        local parsed_backup =
            vim.json.decode(table.concat(backup_content, "\n"))

        assert.equal(1, #parsed_messages.messages)
        local first_message = assert.not_nil(parsed_messages.messages[1])
        assert.equal("Legacy message", first_message.text)
        assert.equal("legacy-1", parsed_metadata.session_id)
        assert.equal("Legacy title", parsed_metadata.title)
        assert.equal(1704067200, parsed_metadata.created_at)
        assert.equal(1704067200, parsed_metadata.updated_at)
        assert.equal("legacy-1", parsed_backup.session_id)
        assert.equal("Legacy title", parsed_backup.title)
    end)
end)
