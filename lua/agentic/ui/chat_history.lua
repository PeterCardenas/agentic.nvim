local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string Raw user input text, not the buffer formatted content
--- @field timestamp integer Unix timestamp when message was sent
--- @field provider_name string

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field provider_name string
--- @field text string Agent response text (concatenated chunks)

--- @class agentic.ui.ChatHistory.ThoughtMessage : agentic.ui.ChatHistory.AgentMessage
--- @field type "thought"

--- @class agentic.ui.ChatHistory.ToolCall : agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id? string
--- @field type "tool_call"

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall

--- @class agentic.ui.ChatHistory.SessionMeta
--- @field session_id string
--- @field acp_session_id? string
--- @field title string
--- @field created_at integer
--- @field updated_at integer

--- @class agentic.ui.ChatHistory.MessagesData
--- @field messages agentic.ui.ChatHistory.Message[]

--- @class agentic.ui.ChatHistory.LegacyStorageData
--- @field session_id? string
--- @field acp_session_id? string
--- @field title? string
--- @field timestamp? integer
--- @field created_at? integer
--- @field updated_at? integer
--- @field messages agentic.ui.ChatHistory.Message[]

--- @class agentic.ui.ChatHistory.MigrationResult
--- @field backup_dir string
--- @field migrated integer
--- @field skipped integer

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field acp_session_id? string
--- @field created_at integer Unix timestamp when session was first created
--- @field updated_at integer Unix timestamp when session was last saved
--- @field messages agentic.ui.ChatHistory.Message[]
--- @field title string
local ChatHistory = {}
ChatHistory.__index = ChatHistory

--- @param parsed table|nil
--- @return integer created_at
--- @return integer updated_at
local function normalize_session_times(parsed)
    if type(parsed) ~= "table" then
        return 0, 0
    end

    local created_at = parsed.created_at or parsed.timestamp or 0
    local updated_at = parsed.updated_at or parsed.timestamp or created_at
    return created_at, updated_at
end

--- @param parsed table
--- @param fallback_id string
--- @return string session_id
local function resolve_session_id(parsed, fallback_id)
    if type(parsed.session_id) == "string" and parsed.session_id ~= "" then
        return parsed.session_id
    end
    return fallback_id
end

--- @return agentic.ui.ChatHistory
function ChatHistory:new()
    local now = os.time()
    local instance = setmetatable({
        session_id = nil,
        acp_session_id = nil,
        created_at = now,
        updated_at = now,
        messages = {},
        title = "",
    }, self)
    return instance
end

--- Generate the project folder name from CWD
--- Normalizes path by replacing slashes, spaces, and colons with underscores
--- Appends first 8 chars of SHA256 hash for collision resistance
function ChatHistory.get_project_folder()
    local cwd = FileSystem.get_git_root()

    local normalized = cwd:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(cwd):sub(1, 8)

    return normalized .. "_" .. hash
end

--- Get the folder path for storing sessions for the current project
--- @return string folder_path
function ChatHistory.get_sessions_folder()
    local base = Config.session_restore.storage_path
        or vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    local project_folder = ChatHistory.get_project_folder()
    return vim.fs.joinpath(base, project_folder)
end

--- Get the base folder for storing all projects' sessions
--- @return string folder_path
function ChatHistory.get_sessions_root()
    local folder_path = Config.session_restore.storage_path
    if folder_path == nil then
        folder_path =
            vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    end
    --- @cast folder_path string
    return folder_path
end

--- Generate the full file path for this session's messages JSON file
--- @param session_id string
--- @return string file_path
function ChatHistory.get_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".json"
    )
end

--- Generate the full file path for this session's metadata JSON file
--- @param session_id string
--- @return string file_path
function ChatHistory.get_metadata_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".meta.json"
    )
end

--- @param parsed table|nil
--- @return boolean is_legacy
local function is_legacy_storage_data(parsed)
    return type(parsed) == "table"
        and (
            parsed.session_id ~= nil
            or parsed.title ~= nil
            or parsed.timestamp ~= nil
            or parsed.created_at ~= nil
            or parsed.updated_at ~= nil
        )
end

--- @param parsed table|nil
--- @return boolean is_messages_data
local function is_messages_storage_data(parsed)
    return type(parsed) == "table" and type(parsed.messages) == "table"
end

--- @param lines string[]|nil
--- @return string|nil content
local function join_file_lines(lines)
    if not lines or #lines == 0 then
        return nil
    end
    return table.concat(lines, "\n")
end

--- @param path string
--- @return table|nil parsed
--- @return string|nil err
local function read_json_file_sync(path)
    if vim.fn.filereadable(path) == 0 then
        return nil, "File not found"
    end

    local content = join_file_lines(vim.fn.readfile(path))
    if not content then
        return nil, "File is empty"
    end

    local ok, parsed = pcall(vim.json.decode, content)
    if not ok or type(parsed) ~= "table" then
        return nil, "JSON decode error"
    end

    return parsed, nil
end

--- @param session_id string
--- @param messages_data agentic.ui.ChatHistory.MessagesData|agentic.ui.ChatHistory.LegacyStorageData
--- @param metadata agentic.ui.ChatHistory.SessionMeta|nil
--- @return agentic.ui.ChatHistory history
local function build_history(session_id, messages_data, metadata)
    local instance = ChatHistory:new()
    instance.session_id = metadata and metadata.session_id or session_id
    instance.acp_session_id = metadata and metadata.acp_session_id or nil
    local created_at, updated_at = normalize_session_times(metadata)
    instance.created_at = created_at
    instance.updated_at = updated_at
    instance.messages = messages_data.messages or {}
    instance.title = metadata and metadata.title or ""
    return instance
end

--- @param session_id string
--- @param metadata_path string
--- @return agentic.ui.ChatHistory.SessionMeta|nil metadata
local function read_metadata_sync(session_id, metadata_path)
    local parsed, err = read_json_file_sync(metadata_path)
    if err ~= nil or type(parsed) ~= "table" then
        return nil
    end

    local created_at, updated_at = normalize_session_times(parsed)

    --- @type agentic.ui.ChatHistory.SessionMeta
    local metadata = {
        session_id = resolve_session_id(parsed, session_id),
        acp_session_id = parsed.acp_session_id,
        title = parsed.title or "",
        created_at = created_at,
        updated_at = updated_at,
    }
    return metadata
end

--- @param path string
--- @param content string
--- @return boolean success
--- @return string|nil err
local function write_json_sync(path, content)
    local dir = vim.fn.fnamemodify(path, ":h")
    local ok, err = FileSystem.mkdirp(dir)
    if not ok then
        return false, err or "Failed to create directory"
    end

    return FileSystem.save_to_disk(path, content)
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    table.insert(self.messages, msg)
end

--- Append text to the last agent or thought message, or create a new one
--- @param msg { type: "agent"|"thought", text: string, provider_name: string  }
function ChatHistory:append_agent_text(msg)
    local last = self.messages[#self.messages]
    if last and last.type == msg.type then
        last.text = last.text .. msg.text
    else
        table.insert(self.messages, msg)
    end
end

--- Update an existing tool_call by merging update data
--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
function ChatHistory:update_tool_call(tool_call_id, update)
    for i = #self.messages, 1, -1 do
        local msg = self.messages[i]
        if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
            self.messages[i] = vim.tbl_deep_extend("force", msg, update)
            return
        end
    end
end

--- Prepend restored messages to prompt in ACP Content format
--- @param messages agentic.ui.ChatHistory.Message[]
--- @param prompt agentic.acp.Content[] The prompt array to prepend to
function ChatHistory.prepend_restored_messages(messages, prompt)
    for _, msg in ipairs(messages) do
        -- Convert stored messages to ACP Content format
        if msg.type == "user" then
            table.insert(prompt, { type = "text", text = "User: " .. msg.text })
        elseif msg.type == "agent" then
            table.insert(
                prompt,
                { type = "text", text = "Assistant: " .. msg.text }
            )
        elseif msg.type == "thought" then
            table.insert(prompt, {
                type = "text",
                text = "Assistant (thinking): " .. msg.text,
            })
        elseif msg.type == "tool_call" and msg.argument then
            local tool_text = string.format(
                "Tool call (%s): %s",
                msg.kind or "unknown",
                msg.argument
            )
            -- Include tool output if available
            if msg.body and #msg.body > 0 then
                tool_text = tool_text
                    .. "\nResult:\n"
                    .. table.concat(msg.body, "\n")
            end
            table.insert(prompt, { type = "text", text = tool_text })
        end
    end
end

--- @param callback fun(err: string|nil)|nil
function ChatHistory:save(callback)
    if not self.session_id then
        Logger.notify("ChatHistory:save() skipped: no session_id")
        if callback then
            callback("No session_id set")
        end
        return
    end

    if #self.messages == 0 then
        if callback then
            callback(nil)
        end
        return
    end

    local messages_path = ChatHistory.get_file_path(self.session_id)
    local metadata_path = ChatHistory.get_metadata_file_path(self.session_id)
    local dir = vim.fn.fnamemodify(messages_path, ":h")

    local dir_ok, dir_err = FileSystem.mkdirp(dir)
    if not dir_ok then
        Logger.debug("Failed to create directory:", dir, dir_err)
        if callback then
            callback(
                "Failed to create directory: " .. (dir_err or "unknown error")
            )
        end
        return
    end

    --- @type agentic.ui.ChatHistory.MessagesData
    local messages_data = {
        messages = self.messages,
    }

    local now = os.time()
    if now <= self.updated_at then
        now = self.updated_at + 1
    end
    self.updated_at = now

    --- @type agentic.ui.ChatHistory.SessionMeta
    local metadata = {
        session_id = self.session_id,
        acp_session_id = self.acp_session_id,
        title = self.title,
        created_at = self.created_at,
        updated_at = self.updated_at,
    }

    local messages_ok, messages_json = pcall(vim.json.encode, messages_data)
    if not messages_ok then
        Logger.debug("JSON encoding failed:", messages_json)
        if callback then
            callback("JSON encoding error")
        end
        return
    end

    local metadata_ok, metadata_json = pcall(vim.json.encode, metadata)
    if not metadata_ok then
        Logger.debug("JSON encoding failed:", metadata_json)
        if callback then
            callback("JSON encoding error")
        end
        return
    end

    FileSystem.write_file(messages_path, messages_json, function(messages_err)
        if messages_err then
            if callback then
                vim.schedule(function()
                    callback(messages_err)
                end)
            end
            return
        end

        FileSystem.write_file(
            metadata_path,
            metadata_json,
            function(metadata_err)
                if callback then
                    vim.schedule(function()
                        callback(metadata_err)
                    end)
                end
            end
        )
    end)
end

--- @param session_id string
--- @param callback fun(history: agentic.ui.ChatHistory|nil, err: string|nil)
function ChatHistory.load(session_id, callback)
    local messages_path = ChatHistory.get_file_path(session_id)
    local metadata_path = ChatHistory.get_metadata_file_path(session_id)

    FileSystem.read_file(messages_path, nil, nil, function(content)
        if not content then
            vim.schedule(function()
                callback(nil, "Failed to read file")
            end)
            return
        end

        local ok, parsed = pcall(vim.json.decode, content)
        if not ok then
            Logger.debug("JSON decode failed:", parsed)
            vim.schedule(function()
                callback(nil, "JSON decode error")
            end)
            return
        end

        if
            is_legacy_storage_data(parsed) and is_messages_storage_data(parsed)
        then
            --- @cast parsed agentic.ui.ChatHistory.LegacyStorageData
            local created_at, updated_at = normalize_session_times(parsed)
            --- @type agentic.ui.ChatHistory.SessionMeta
            local legacy_metadata = {
                session_id = resolve_session_id(parsed, session_id),
                acp_session_id = parsed.acp_session_id,
                title = parsed.title or "",
                created_at = created_at,
                updated_at = updated_at,
            }
            local instance = build_history(session_id, parsed, legacy_metadata)
            vim.schedule(function()
                callback(instance, nil)
            end)
            return
        end

        if not is_messages_storage_data(parsed) then
            vim.schedule(function()
                callback(nil, "Invalid session data")
            end)
            return
        end

        --- @cast parsed agentic.ui.ChatHistory.MessagesData
        local metadata = read_metadata_sync(session_id, metadata_path)
        local instance = build_history(session_id, parsed, metadata)

        vim.schedule(function()
            callback(instance, nil)
        end)
    end)
end

--- Delete a session file from disk
--- @param session_id string
--- @param callback fun(err: string|nil)|nil
function ChatHistory.delete_session(session_id, callback)
    local messages_path = ChatHistory.get_file_path(session_id)
    local metadata_path = ChatHistory.get_metadata_file_path(session_id)
    local removed_any = false

    local function remove_if_exists(path)
        if vim.uv.fs_stat(path) == nil then
            return true, nil
        end

        removed_any = true
        local ok, err = os.remove(path)
        return ok, err
    end

    local messages_ok, messages_err = remove_if_exists(messages_path)
    local metadata_ok, metadata_err = remove_if_exists(metadata_path)

    if callback then
        if not removed_any then
            callback("Failed to delete session file")
        elseif messages_ok and metadata_ok then
            callback(nil)
        else
            callback(
                messages_err or metadata_err or "Failed to delete session file"
            )
        end
    end
end

--- List all sessions for the current project, sorted by updated_at descending
--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
function ChatHistory.list_sessions(callback)
    local folder = ChatHistory.get_sessions_folder()
    local sessions = {}
    local sessions_by_id = {}

    if vim.fn.isdirectory(folder) == 0 then
        Logger.debug("Session folder does not exist:", folder)
        callback(sessions)
        return
    end

    for filename, file_type in vim.fs.dir(folder) do
        local session_id = filename:match("^(.*)%.meta%.json$")
        if file_type == "file" and session_id then
            local file_path = vim.fs.joinpath(folder, filename)
            local parsed, err = read_json_file_sync(file_path)
            if err == nil and type(parsed) == "table" then
                local created_at, updated_at = normalize_session_times(parsed)

                --- @type agentic.ui.ChatHistory.SessionMeta
                local session = {
                    session_id = resolve_session_id(parsed, session_id),
                    acp_session_id = parsed.acp_session_id,
                    title = parsed.title or "",
                    created_at = created_at,
                    updated_at = updated_at,
                }
                sessions_by_id[session.session_id] = session
            else
                Logger.debug(
                    "Failed to parse session metadata file:",
                    file_path
                )
            end
        end
    end

    for filename, file_type in vim.fs.dir(folder) do
        local session_id = filename:match("^(.*)%.json$")
        if
            file_type == "file"
            and session_id
            and not filename:match("%.meta%.json$")
            and not sessions_by_id[session_id]
        then
            local file_path = vim.fs.joinpath(folder, filename)
            local parsed, err = read_json_file_sync(file_path)
            if
                err == nil
                and is_legacy_storage_data(parsed)
                and is_messages_storage_data(parsed)
            then
                --- @cast parsed agentic.ui.ChatHistory.LegacyStorageData
                local created_at, updated_at = normalize_session_times(parsed)

                --- @type agentic.ui.ChatHistory.SessionMeta
                local session = {
                    session_id = resolve_session_id(parsed, session_id),
                    acp_session_id = parsed.acp_session_id,
                    title = parsed.title or "",
                    created_at = created_at,
                    updated_at = updated_at,
                }
                sessions_by_id[session.session_id] = session
            end
        end
    end

    for _, session in pairs(sessions_by_id) do
        table.insert(sessions, session)
    end

    table.sort(sessions, function(a, b)
        return a.updated_at > b.updated_at
    end)

    callback(sessions)
end

--- Back up and migrate all legacy monolithic session files to split storage.
--- @return agentic.ui.ChatHistory.MigrationResult|nil result
function ChatHistory.migrate_all_legacy_sessions()
    local sessions_root = ChatHistory.get_sessions_root()
    local timestamp = os.date("%Y%m%d_%H%M%S")
    local backup_dir =
        vim.fs.joinpath(sessions_root, "_legacy_backups", timestamp)
    --- @type agentic.ui.ChatHistory.MigrationResult
    local result = {
        backup_dir = backup_dir,
        migrated = 0,
        skipped = 0,
    }

    if vim.fn.isdirectory(sessions_root) == 0 then
        return result
    end

    for project_folder, file_type in vim.fs.dir(sessions_root) do
        if file_type == "directory" and project_folder ~= "_legacy_backups" then
            local project_path = vim.fs.joinpath(sessions_root, project_folder)
            for filename, child_type in vim.fs.dir(project_path) do
                local session_id = filename:match("^(.*)%.json$")
                if
                    child_type == "file"
                    and session_id
                    and not filename:match("%.meta%.json$")
                then
                    local messages_path =
                        vim.fs.joinpath(project_path, filename)
                    local metadata_path = vim.fs.joinpath(
                        project_path,
                        session_id .. ".meta.json"
                    )
                    if vim.uv.fs_stat(metadata_path) ~= nil then
                        result.skipped = result.skipped + 1
                    else
                        local content =
                            join_file_lines(vim.fn.readfile(messages_path))
                        local ok, parsed = pcall(vim.json.decode, content or "")
                        if
                            ok
                            and is_legacy_storage_data(parsed)
                            and is_messages_storage_data(parsed)
                            and content ~= nil
                        then
                            local backup_path = vim.fs.joinpath(
                                backup_dir,
                                project_folder,
                                filename
                            )
                            local backup_ok, backup_err =
                                write_json_sync(backup_path, content)
                            if not backup_ok then
                                Logger.debug(
                                    "Failed to back up legacy session:",
                                    backup_path,
                                    backup_err
                                )
                                result.skipped = result.skipped + 1
                            else
                                --- @cast parsed agentic.ui.ChatHistory.LegacyStorageData
                                local messages_json = vim.json.encode({
                                    messages = parsed.messages,
                                })
                                local created_at, updated_at =
                                    normalize_session_times(parsed)
                                local metadata_json = vim.json.encode({
                                    session_id = resolve_session_id(
                                        parsed,
                                        session_id
                                    ),
                                    acp_session_id = parsed.acp_session_id,
                                    title = parsed.title or "",
                                    created_at = created_at,
                                    updated_at = updated_at,
                                })

                                local messages_ok, messages_err =
                                    write_json_sync(
                                        messages_path,
                                        messages_json
                                    )
                                local metadata_ok, metadata_err =
                                    write_json_sync(
                                        metadata_path,
                                        metadata_json
                                    )

                                if messages_ok and metadata_ok then
                                    result.migrated = result.migrated + 1
                                else
                                    Logger.debug(
                                        "Failed to migrate legacy session:",
                                        messages_path,
                                        messages_err or metadata_err
                                    )
                                    result.skipped = result.skipped + 1
                                end
                            end
                        else
                            result.skipped = result.skipped + 1
                        end
                    end
                end
            end
        end
    end

    return result
end

return ChatHistory
