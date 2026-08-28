local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")
local FileSystem = require("agentic.utils.file_system")
local ToolCallBody = require("agentic.utils.tool_call_body")

--- @class agentic.ui.ChatHistory.UserMessage
--- @field type "user"
--- @field text string
--- @field timestamp integer
--- @field provider_name string

--- @class agentic.ui.ChatHistory.AgentMessage
--- @field type "agent"
--- @field provider_name string
--- @field text string

--- @class agentic.ui.ChatHistory.ThoughtMessage : agentic.ui.ChatHistory.AgentMessage
--- @field type "thought"

--- @class agentic.ui.ChatHistory.ToolCall : agentic.ui.MessageWriter.ToolCallBase
--- @field tool_call_id? string
--- @field type "tool_call"

--- @class agentic.ui.ChatHistory.TurnEndMessage
--- @field type "turn_end"
--- @field timestamp integer
--- @field duration string

--- @alias agentic.ui.ChatHistory.Message
--- | agentic.ui.ChatHistory.UserMessage
--- | agentic.ui.ChatHistory.AgentMessage
--- | agentic.ui.ChatHistory.ThoughtMessage
--- | agentic.ui.ChatHistory.ToolCall
--- | agentic.ui.ChatHistory.TurnEndMessage

--- @class agentic.ui.ChatHistory.SessionMeta
--- @field session_id string
--- @field acp_session_id? string
--- @field title string
--- @field created_at integer
--- @field updated_at integer
--- @field message_count? integer

--- @class agentic.ui.ChatHistory.ReplaySource
--- @field kind "jsonl"|"messages"
--- @field session_id? string
--- @field sessions_folder? string
--- @field messages? agentic.ui.ChatHistory.Message[]

--- @class agentic.ui.ChatHistory.MigrationResult
--- @field backup_dir string
--- @field migrated integer
--- @field recovered integer
--- @field skipped integer
--- @field failed integer
--- @field errors string[]

--- @class agentic.ui.ChatHistory
--- @field session_id? string
--- @field acp_session_id? string
--- @field created_at integer
--- @field updated_at integer
--- @field messages agentic.ui.ChatHistory.Message[] Compatibility field; live sessions keep this empty.
--- @field message_count integer
--- @field has_user_message boolean
--- @field title string
--- @field _pending_records table[]
--- @field _sessions_folder string
--- @field _meta_written boolean
--- @field _loaded_from_disk boolean
--- @field _event_write_error? string
--- @field _replay_progress table<string, integer>
local ChatHistory = {}
ChatHistory.__index = ChatHistory

local BACKUP_DIR_NAME = "_jsonl_migration_backups"

--- @param timestamp integer
--- @param duration string
--- @return string message
function ChatHistory.format_turn_end(timestamp, duration)
    return string.format(
        "\n### 🏁 %s (%s)\n-----",
        os.date("%Y-%m-%d %H:%M:%S", timestamp),
        duration
    )
end

--- @return agentic.ui.ChatHistory history
--- @param sessions_folder? string
function ChatHistory:new(sessions_folder)
    local now = os.time()
    --- @type agentic.ui.ChatHistory
    local instance = setmetatable({
        session_id = nil,
        acp_session_id = nil,
        created_at = now,
        updated_at = now,
        messages = {},
        message_count = 0,
        has_user_message = false,
        title = "",
        _pending_records = {},
        _sessions_folder = sessions_folder or ChatHistory.get_sessions_folder(),
        _meta_written = false,
        _loaded_from_disk = false,
        _event_write_error = nil,
        _replay_progress = {},
    }, self)
    return instance
end

--- @param tab_page_id integer|nil
--- @return string cwd
local function get_valid_tab_cwd(tab_page_id)
    if tab_page_id and vim.api.nvim_tabpage_is_valid(tab_page_id) then
        local tab_number = vim.api.nvim_tabpage_get_number(tab_page_id)
        local winid = vim.api.nvim_tabpage_get_win(tab_page_id)
        return vim.fn.getcwd(winid, tab_number)
    end
    return vim.fn.getcwd()
end

--- @return boolean
function ChatHistory:has_user_messages()
    if self.has_user_message then
        return true
    end
    for _, message in ipairs(self.messages or {}) do
        if message.type == "user" then
            return true
        end
    end
    return false
end

--- @param tab_page_id integer|nil
function ChatHistory.get_project_folder(tab_page_id)
    local cwd = get_valid_tab_cwd(tab_page_id)
    local project_root = FileSystem.get_git_root(cwd)
    local normalized = project_root:gsub("[/\\%s:]", "_"):gsub("^_+", "")
    local hash = vim.fn.sha256(project_root):sub(1, 8)
    return normalized .. "_" .. hash
end

--- @param tab_page_id integer|nil
--- @return string folder_path
function ChatHistory.get_sessions_root(tab_page_id)
    local session_restore = Config.session_restore or {}
    local folder_path = session_restore.storage_path
        or vim.fs.joinpath(vim.fn.stdpath("cache"), "agentic", "sessions")
    --- @cast folder_path string
    if vim.fn.isabsolutepath(folder_path) ~= 1 then
        folder_path =
            vim.fs.joinpath(get_valid_tab_cwd(tab_page_id), folder_path)
    end
    return vim.fn.fnamemodify(folder_path, ":p")
end

--- @param tab_page_id integer|nil
--- @return string folder_path
local function get_sessions_folder_for_project(project_folder, tab_page_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_root(tab_page_id),
        project_folder
    )
end

--- @param tab_page_id integer|nil
function ChatHistory.get_sessions_folder(tab_page_id)
    return get_sessions_folder_for_project(
        ChatHistory.get_project_folder(tab_page_id),
        tab_page_id
    )
end

--- @param session_id string
--- @return string file_path
function ChatHistory.get_jsonl_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".jsonl"
    )
end

--- @param session_id string
--- @return string file_path
function ChatHistory.get_file_path(session_id)
    return ChatHistory.get_jsonl_file_path(session_id)
end

--- @param session_id string
--- @return string file_path
function ChatHistory.get_legacy_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".json"
    )
end

--- @param session_id string
--- @return string file_path
function ChatHistory.get_metadata_file_path(session_id)
    return vim.fs.joinpath(
        ChatHistory.get_sessions_folder(),
        session_id .. ".meta.json"
    )
end

--- @param session_id string
--- @return string file_path
function ChatHistory:_get_jsonl_file_path(session_id)
    return vim.fs.joinpath(self._sessions_folder, session_id .. ".jsonl")
end

--- @param session_id string
--- @return string file_path
function ChatHistory:_get_metadata_file_path(session_id)
    return vim.fs.joinpath(self._sessions_folder, session_id .. ".meta.json")
end

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

--- @param msg agentic.ui.ChatHistory.Message
--- @return agentic.ui.ChatHistory.Message compacted
local function compact_message(msg)
    if msg.type ~= "tool_call" or not msg.body then
        return msg
    end
    local compacted = vim.tbl_deep_extend("force", {}, msg)
    compacted.body = ToolCallBody.truncate_for_display(
        msg.body,
        ToolCallBody.get_max_display_lines()
    )
    return compacted
end

--- @param path string
--- @return string|nil content
local function read_file_sync(path)
    if vim.fn.filereadable(path) == 0 then
        return nil
    end
    local lines = vim.fn.readfile(path)
    if not lines then
        return nil
    end
    if #lines == 0 then
        return ""
    end
    return table.concat(lines, "\n")
end

--- @param path string
--- @param callback fun(content: string|nil)
local function read_file_async(path, callback)
    vim.uv.fs_open(path, "r", 438, function(open_err, fd)
        if open_err or not fd then
            vim.schedule(function()
                callback(nil)
            end)
            return
        end

        vim.uv.fs_fstat(fd, function(stat_err, stat)
            if stat_err or not stat then
                vim.uv.fs_close(fd)
                vim.schedule(function()
                    callback(nil)
                end)
                return
            end

            vim.uv.fs_read(fd, stat.size, 0, function(read_err, content)
                vim.uv.fs_close(fd)
                vim.schedule(function()
                    callback(read_err and nil or content)
                end)
            end)
        end)
    end)
end

--- @type fun(path: string, content: string): boolean, string|nil
local write_file_atomic_sync = function(_path, _content)
    error("metadata writer not initialized")
end
--- @type fun(jsonl: string): boolean
local validate_event_jsonl

--- @param content string|nil
--- @param session_id string
--- @return agentic.ui.ChatHistory.SessionMeta|nil metadata
local function decode_session_metadata(content, session_id)
    local ok, record = pcall(vim.json.decode, content or "")
    if not ok or type(record) ~= "table" then
        return nil
    end
    if record.type ~= nil and record.type ~= "meta" then
        return nil
    end
    if record.type == "meta" then
        record.type = nil
    end
    if
        type(record.session_id) == "string"
        and record.session_id ~= ""
        and record.session_id ~= session_id
    then
        return nil
    end
    if
        type(record.title) ~= "string"
        or type(record.created_at) ~= "number"
        or type(record.updated_at) ~= "number"
    then
        return nil
    end
    local created_at, updated_at = normalize_session_times(record)
    --- @type agentic.ui.ChatHistory.SessionMeta
    local metadata = {
        session_id = resolve_session_id(record, session_id),
        acp_session_id = record.acp_session_id,
        title = record.title,
        created_at = created_at,
        updated_at = updated_at,
        message_count = record.message_count,
    }
    return metadata
end

--- @param callback fun(metadata: agentic.ui.ChatHistory.SessionMeta|nil, err: string|nil)
local function read_session_metadata(session_id, sessions_folder, callback)
    local metadata_path =
        vim.fs.joinpath(sessions_folder, session_id .. ".meta.json")

    local metadata_file = vim.uv.fs_stat(metadata_path)
    if not metadata_file then
        vim.schedule(function()
            callback(nil, "Invalid session metadata")
        end)
        return
    end

    read_file_async(metadata_path, function(content)
        local metadata = decode_session_metadata(content, session_id)
        if not metadata then
            callback(nil, "Invalid session metadata")
            return
        end
        read_file_async(
            vim.fs.joinpath(sessions_folder, session_id .. ".jsonl"),
            function(jsonl_content)
                if
                    not jsonl_content
                    or not validate_event_jsonl(jsonl_content)
                then
                    callback(nil, "Invalid session events")
                    return
                end
                callback(metadata, nil)
            end
        )
    end)
end

--- @param path string
--- @return table|nil parsed
--- @return string|nil err
local function read_json_file_sync(path)
    local content = read_file_sync(path)
    if not content then
        return nil, "File not found"
    end
    local ok, parsed = pcall(vim.json.decode, content)
    if not ok or type(parsed) ~= "table" then
        return nil, "JSON decode error"
    end
    return parsed, nil
end

--- @param path string
--- @param content string
--- @return boolean success
--- @return string|nil err
local function write_file_sync(path, content)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        local ok, err = FileSystem.mkdirp(dir)
        if not ok then
            return false, err
        end
    end
    return FileSystem.save_to_disk(path, content)
end

--- @param path string
--- @param content string
--- @return boolean success
--- @return string|nil err
write_file_atomic_sync = function(path, content)
    local tmp_path = path .. ".tmp." .. tostring(vim.uv.hrtime())
    local ok, err = write_file_sync(tmp_path, content)
    if not ok then
        os.remove(tmp_path)
        return false, err
    end
    local renamed, rename_err = os.rename(tmp_path, path)
    if not renamed then
        os.remove(tmp_path)
        return false, tostring(rename_err or "rename failed")
    end
    return true, nil
end

--- @param path string
--- @param line string
--- @return boolean success
--- @return string|nil err
local function append_line_sync(path, line)
    local dir = vim.fn.fnamemodify(path, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        local ok, err = FileSystem.mkdirp(dir)
        if not ok then
            return false, err
        end
    end

    local baseline_stat = vim.uv.fs_stat(path)
    local baseline_size = baseline_stat and baseline_stat.size or 0
    local expected = baseline_size == 0 and line or "\n" .. line

    local file, open_err = io.open(path, "a")
    if not file then
        return false, tostring(open_err)
    end

    if baseline_size > 0 then
        local ok, err = file:write("\n")
        if not ok then
            file:close()
            return false, "write failed: " .. tostring(err or "unknown error")
        end
    end

    local ok, err = file:write(line)
    if not ok then
        file:close()
        return false, "write failed: " .. tostring(err or "unknown error")
    end

    local close_ok, close_err = file:close()
    if not close_ok then
        local committed_file = io.open(path, "r")
        if committed_file then
            local final_stat = vim.uv.fs_stat(path)
            local committed = final_stat
                and final_stat.size == baseline_size + #expected
            if committed and committed_file:seek("set", baseline_size) then
                committed = committed_file:read(#expected) == expected
            else
                committed = false
            end
            committed_file:close()
            if committed then
                return true, nil
            end
        end
        return false, "close failed: " .. tostring(close_err or "unknown error")
    end
    return true, nil
end

--- @param record table
--- @return boolean success
--- @return string|nil err
function ChatHistory:_append_record(record)
    if not self.session_id then
        return false, "No session_id set"
    end
    local ok, encoded = pcall(vim.json.encode, record)
    if not ok then
        return false, "JSON encoding error"
    end
    return append_line_sync(self:_get_jsonl_file_path(self.session_id), encoded)
end

--- @return table record
function ChatHistory:_meta_record()
    --- @type table
    local record = {
        session_id = self.session_id,
        acp_session_id = self.acp_session_id,
        title = self.title,
        created_at = self.created_at,
        updated_at = self.updated_at,
        message_count = self.message_count,
    }
    return record
end

--- @return boolean success
--- @return string|nil err
function ChatHistory:_write_meta_record()
    if not self.session_id then
        return false, "No session_id set"
    end
    local ok, encoded = pcall(vim.json.encode, self:_meta_record())
    if not ok then
        return false, "JSON encoding error"
    end
    local success, err = write_file_atomic_sync(
        self:_get_metadata_file_path(self.session_id),
        encoded
    )
    if success then
        self._meta_written = true
    end
    return success, err
end

--- @return boolean success
--- @return string|nil err
function ChatHistory:_flush_pending_records()
    if not self.session_id or not self.has_user_message then
        return true, nil
    end
    local pending_records = self._pending_records
    for index, record in ipairs(pending_records) do
        local ok, err = self:_append_record(record)
        if not ok then
            self._pending_records = vim.list_slice(pending_records, index)
            return false, err
        end
    end
    self._pending_records = {}
    return true, nil
end

--- All records enter here; this is the sole persistence coordinator.
--- @param record table
--- @return boolean success
--- @return string|nil err
function ChatHistory:_ingest_record(record)
    table.insert(self._pending_records, record)
    if record.type == "message" and record.message.type == "user" then
        self.has_user_message = true
    end
    if not self.session_id or not self.has_user_message then
        return true, nil
    end
    local ok, err = self:_flush_pending_records()
    if ok then
        self._event_write_error = nil
    end
    return ok, err
end

--- @param msg agentic.ui.ChatHistory.Message
function ChatHistory:add_message(msg)
    self.message_count = self.message_count + 1
    self.updated_at = math.max(os.time(), self.updated_at + 1)
    local record = {
        type = "message",
        message = msg,
    }
    local ok, err = self:_ingest_record(record)
    if not ok then
        self._event_write_error = err or "Failed to append chat history"
        Logger.debug("Failed to append chat history message:", err)
    end
end

--- @param msg { type: "agent"|"thought", text: string, provider_name: string }
function ChatHistory:append_agent_text(msg)
    self:add_message(msg --[[@as agentic.ui.ChatHistory.Message]])
end

--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
function ChatHistory:update_tool_call(tool_call_id, update)
    local record = {
        type = "tool_call_update",
        tool_call_id = tool_call_id,
        update = update,
    }
    local ok, err = self:_ingest_record(record)
    if not ok then
        self._event_write_error = err or "Failed to append chat history update"
        Logger.debug("Failed to append chat history tool update:", err)
    end
end

--- @param messages agentic.ui.ChatHistory.Message[]
--- @param msg agentic.ui.ChatHistory.Message
local function append_replayed_message(messages, msg)
    local last = messages[#messages]
    if
        last
        and (msg.type == "agent" or msg.type == "thought")
        and last.type == msg.type
    then
        last.text = (last.text or "") .. (msg.text or "")
        return
    end
    table.insert(messages, msg)
end

--- @param messages agentic.ui.ChatHistory.Message[]
--- @param tool_call_id string
--- @param update agentic.ui.ChatHistory.ToolCall
local function apply_tool_call_update(messages, tool_call_id, update)
    for i = #messages, 1, -1 do
        local msg = messages[i]
        if msg.type == "tool_call" and msg.tool_call_id == tool_call_id then
            messages[i] = vim.tbl_deep_extend("force", msg, update)
            return
        end
    end
end

--- @param session_id string
--- @param content string
--- @return agentic.ui.ChatHistory|nil history
--- @return string|nil err
local function parse_jsonl_history(session_id, content, sessions_folder)
    local history = ChatHistory:new(sessions_folder)
    history.session_id = session_id
    history.messages = {}
    history.message_count = 0
    history.has_user_message = false
    history._meta_written = true
    local parsed_message_count = 0

    for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
        if line ~= "" then
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= "table" then
                return nil, "JSONL decode error"
            end

            if record.type == "meta" then
                return nil, "Event JSONL must not contain metadata"
            elseif
                record.type == "message" and type(record.message) == "table"
            then
                append_replayed_message(history.messages, record.message)
                parsed_message_count = parsed_message_count + 1
                if record.message.type == "user" then
                    history.has_user_message = true
                end
            elseif
                record.type == "tool_call_update"
                and type(record.tool_call_id) == "string"
                and type(record.update) == "table"
            then
                apply_tool_call_update(
                    history.messages,
                    record.tool_call_id,
                    record.update
                )
            else
                return nil, "JSONL decode error"
            end
        end
    end

    history.message_count = parsed_message_count
    history.session_id = session_id
    history._loaded_from_disk = true

    return history, nil
end

--- @param history agentic.ui.ChatHistory
--- @param metadata table|nil
--- @return boolean valid
local function apply_metadata(history, metadata, requested_session_id)
    if
        type(metadata) ~= "table"
        or (metadata.type ~= nil and metadata.type ~= "meta")
        or type(metadata.session_id) ~= "string"
        or metadata.session_id == ""
        or type(metadata.title) ~= "string"
        or type(metadata.created_at) ~= "number"
        or type(metadata.updated_at) ~= "number"
    then
        return false
    end
    if metadata.session_id ~= requested_session_id then
        return false
    end
    history.session_id = requested_session_id
    history.acp_session_id = metadata.acp_session_id
    history.title = metadata.title or ""
    history.created_at, history.updated_at = normalize_session_times(metadata)
    if type(metadata.message_count) == "number" then
        history.message_count = math.floor(metadata.message_count)
    end
    return true
end

--- @param session_id string
--- @param sessions_folder? string
--- @return agentic.ui.ChatHistory|nil history
--- @return string|nil err
function ChatHistory.load_sync(session_id, sessions_folder)
    sessions_folder = sessions_folder or ChatHistory.get_sessions_folder()
    local metadata = read_json_file_sync(
        vim.fs.joinpath(sessions_folder, session_id .. ".meta.json")
    )
    if not metadata then
        return nil, "Invalid session metadata"
    end

    local content =
        read_file_sync(vim.fs.joinpath(sessions_folder, session_id .. ".jsonl"))
    if not content then
        return nil, "Failed to read file"
    end

    local history, err =
        parse_jsonl_history(session_id, content, sessions_folder)
    if history then
        if not apply_metadata(history, metadata, session_id) then
            return nil, "Invalid session metadata"
        end
    end
    return history, err
end

--- @param session_id string
--- @param callback fun(history: agentic.ui.ChatHistory|nil, err: string|nil)
--- @param sessions_folder? string
function ChatHistory.load(session_id, callback, sessions_folder)
    sessions_folder = sessions_folder or ChatHistory.get_sessions_folder()
    read_session_metadata(
        session_id,
        sessions_folder,
        function(metadata, metadata_err)
            if not metadata then
                callback(nil, metadata_err or "Invalid session metadata")
                return
            end

            read_file_async(
                vim.fs.joinpath(sessions_folder, session_id .. ".jsonl"),
                function(content)
                    if not content then
                        callback(nil, "Failed to read file")
                        return
                    end

                    local history, err = parse_jsonl_history(
                        session_id,
                        content,
                        sessions_folder
                    )
                    if not history then
                        callback(nil, err)
                        return
                    end
                    if not apply_metadata(history, metadata, session_id) then
                        callback(nil, "Invalid session metadata")
                        return
                    end
                    callback(history, nil)
                end
            )
        end
    )
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

    if not self.has_user_message then
        if callback then
            callback(nil)
        end
        return
    end

    local ok, err = self:_flush_pending_records()
    if ok then
        self._event_write_error = nil
        ok, err = self:_write_meta_record()
        if not ok then
            self._event_write_error = err or "Failed to write session metadata"
        end
    else
        self._event_write_error = err or self._event_write_error
    end

    if callback then
        if ok then
            callback(nil)
        else
            callback(err or "Failed to save chat history")
        end
    end
end

--- @return agentic.ui.ChatHistory.ReplaySource source
function ChatHistory:get_replay_source()
    if self._loaded_from_disk then
        return {
            kind = "messages",
            messages = self.messages,
            sessions_folder = self._sessions_folder,
        }
    end
    if not self.has_user_message then
        return { kind = "messages", messages = {} }
    end
    if self.session_id then
        return {
            kind = "jsonl",
            session_id = self.session_id,
            sessions_folder = self._sessions_folder,
        }
    end
    return { kind = "messages", messages = self.messages }
end

--- @param source agentic.ui.ChatHistory.ReplaySource|agentic.ui.ChatHistory.Message[]
--- @return agentic.ui.ChatHistory.Message[]|nil messages
--- @return string|nil err
function ChatHistory.collect_messages(source)
    if vim.islist(source) then
        --- @cast source agentic.ui.ChatHistory.Message[]
        return source, nil
    end
    --- @cast source agentic.ui.ChatHistory.ReplaySource
    if source.kind == "messages" then
        return source.messages or {}, nil
    end
    if source.session_id then
        local history, err =
            ChatHistory.load_sync(source.session_id, source.sessions_folder)
        if not history then
            return nil, err or "Failed to load chat history"
        end
        return history.messages, nil
    end
    return {}, nil
end

--- @param source agentic.ui.ChatHistory.ReplaySource|agentic.ui.ChatHistory.Message[]
--- @return boolean success
--- @return string|nil err
--- @return agentic.ui.ChatHistory.Message[]|nil messages
function ChatHistory:append_replay_source(source)
    if vim.islist(source) then
        --- @cast source agentic.ui.ChatHistory.Message[]
        for _, message in ipairs(source) do
            self:add_message(message)
        end
        return true, nil, source
    end

    --- @cast source agentic.ui.ChatHistory.ReplaySource
    if source.kind == "messages" then
        for _, message in ipairs(source.messages or {}) do
            self:add_message(message)
        end
        return true, nil, source.messages or {}
    end

    if not source.session_id then
        return true, nil, {}
    end

    if source.session_id == self.session_id then
        return true, nil, {}
    end

    local path = vim.fs.joinpath(
        source.sessions_folder or ChatHistory.get_sessions_folder(),
        source.session_id .. ".jsonl"
    )
    if vim.fn.filereadable(path) == 0 then
        return false, "Replay source not found"
    end

    local source_key = path
    local progress = self._replay_progress[source_key] or 0
    if progress > 0 and #self._pending_records > 0 then
        local flushed, flush_err = self:_flush_pending_records()
        if not flushed then
            return false, flush_err
        end
    end

    local messages = {}
    local record_index = 0
    for line in io.lines(path) do
        if line ~= "" then
            record_index = record_index + 1
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= "table" then
                return false, "JSONL decode error"
            end

            if record_index > progress then
                -- Progress tracks records accepted into the destination queue;
                -- retries must not enqueue a record twice after a flush failure.
                self._replay_progress[source_key] = record_index
                if record.type == "message" then
                    self.message_count = self.message_count + 1
                    append_replayed_message(messages, record.message)
                    local append_ok, append_err = self:_ingest_record(record)
                    if not append_ok then
                        return false, append_err
                    end
                elseif record.type == "tool_call_update" then
                    apply_tool_call_update(
                        messages,
                        record.tool_call_id,
                        record.update
                    )
                    local append_ok, append_err = self:_ingest_record(record)
                    if not append_ok then
                        return false, append_err
                    end
                end
            end
        end
    end

    return true, nil, messages
end

--- @param messages_or_source agentic.ui.ChatHistory.Message[]|agentic.ui.ChatHistory.ReplaySource
--- @param prompt agentic.acp.Content[]
--- @return boolean success
--- @return string|nil err
function ChatHistory.prepend_restored_messages(messages_or_source, prompt)
    local messages, err = ChatHistory.collect_messages(messages_or_source)
    if not messages then
        return false, err
    end
    for _, msg in ipairs(messages) do
        if msg.type == "user" then
            table.insert(prompt, { type = "text", text = "User: " .. msg.text })
        elseif msg.type == "agent" then
            table.insert(prompt, {
                type = "text",
                text = "Assistant: " .. msg.text,
            })
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
            if msg.body and #msg.body > 0 then
                tool_text = tool_text
                    .. "\nResult:\n"
                    .. table.concat(msg.body, "\n")
            end
            table.insert(prompt, { type = "text", text = tool_text })
        end
    end
    return true, nil
end

--- @param session_id string
--- @param callback fun(err: string|nil)|nil
--- @param sessions_folder? string
function ChatHistory.delete_session(session_id, callback, sessions_folder)
    sessions_folder = sessions_folder or ChatHistory.get_sessions_folder()
    local paths = {
        vim.fs.joinpath(sessions_folder, session_id .. ".jsonl"),
        vim.fs.joinpath(sessions_folder, session_id .. ".meta.json"),
    }
    local ok = true
    local err = nil
    for _, path in ipairs(paths) do
        if vim.uv.fs_stat(path) ~= nil then
            local removed, remove_err = os.remove(path)
            if not removed then
                ok = false
                err = remove_err
            end
        end
    end
    if callback then
        if ok then
            callback(nil)
        else
            callback(err or "Failed to delete session files")
        end
    end
end

--- @param callback fun(sessions: agentic.ui.ChatHistory.SessionMeta[])
--- @param sessions_folder? string
function ChatHistory.list_sessions(callback, sessions_folder)
    local folder = sessions_folder or ChatHistory.get_sessions_folder()
    local sessions = {}
    if vim.fn.isdirectory(folder) == 0 then
        callback(sessions)
        return
    end

    for filename, file_type in vim.fs.dir(folder) do
        if file_type == "file" then
            local session_id = filename:match("^(.*)%.meta%.json$")
            if
                session_id
                and vim.uv.fs_stat(
                    vim.fs.joinpath(folder, session_id .. ".jsonl")
                )
            then
                local metadata = decode_session_metadata(
                    read_file_sync(
                        vim.fs.joinpath(folder, session_id .. ".meta.json")
                    ),
                    session_id
                )
                if metadata then
                    table.insert(sessions, metadata)
                end
            end
        end
    end
    table.sort(sessions, function(a, b)
        return a.updated_at > b.updated_at
    end)
    callback(sessions)
end

--- @param message table|nil
--- @return boolean valid
local function is_valid_message(message)
    if type(message) ~= "table" or type(message.type) ~= "string" then
        return false
    end
    if message.type == "user" then
        return type(message.text) == "string"
            and type(message.timestamp) == "number"
            and type(message.provider_name) == "string"
    elseif message.type == "agent" or message.type == "thought" then
        return type(message.text) == "string"
            and type(message.provider_name) == "string"
    elseif message.type == "turn_end" then
        return type(message.timestamp) == "number"
            and type(message.duration) == "string"
    elseif message.type == "tool_call" then
        return (
            message.tool_call_id == nil
            or type(message.tool_call_id) == "string"
        )
            and (message.status == nil or type(message.status) == "string")
            and (message.kind == nil or type(message.kind) == "string")
            and (message.argument == nil or type(message.argument) == "string")
    end
    return false
end

--- @param messages table|nil
--- @return boolean valid
local function is_valid_message_list(messages)
    if type(messages) ~= "table" or not vim.islist(messages) then
        return false
    end
    for _, message in ipairs(messages) do
        if not is_valid_message(message) then
            return false
        end
    end
    return true
end

--- @param parsed table|nil
--- @return boolean is_legacy
local function is_legacy_storage_data(parsed)
    if
        type(parsed) ~= "table"
        or type(parsed.messages) ~= "table"
        or not vim.islist(parsed.messages)
    then
        return false
    end
    return is_valid_message_list(parsed.messages)
end

--- @param messages table
--- @param metadata table
--- @return string|nil jsonl
local function encode_jsonl(messages, metadata)
    if not is_valid_message_list(messages) then
        return nil
    end
    local lines = {}
    local ok, encoded_meta = pcall(
        vim.json.encode,
        vim.tbl_extend("force", {
            type = "meta",
        }, metadata)
    )
    if not ok then
        return nil
    end
    table.insert(lines, encoded_meta)

    for _, message in ipairs(messages) do
        local ok_msg, encoded_msg = pcall(vim.json.encode, {
            type = "message",
            message = compact_message(message),
        })
        if not ok_msg then
            return nil
        end
        table.insert(lines, encoded_msg)
    end

    return table.concat(lines, "\n")
end

--- @param jsonl string
--- @return boolean valid
local function validate_jsonl(jsonl)
    if jsonl == "" then
        return false
    end
    local has_record = false
    for _, line in ipairs(vim.split(jsonl, "\n", { plain = true })) do
        if line:match("%S") then
            has_record = true
            local ok, record = pcall(vim.json.decode, line)
            if
                not ok
                or type(record) ~= "table"
                or type(record.type) ~= "string"
            then
                return false
            end
            if record.type == "meta" then
                if
                    type(record.session_id) ~= "string"
                    or record.session_id == ""
                    or type(record.title) ~= "string"
                    or type(record.created_at) ~= "number"
                    or type(record.updated_at) ~= "number"
                    or (
                        record.message_count ~= nil
                        and type(record.message_count) ~= "number"
                    )
                then
                    return false
                end
            elseif
                record.type == "message"
                and not is_valid_message(record.message)
            then
                return false
            elseif
                record.type == "tool_call_update"
                and (
                    type(record.tool_call_id) ~= "string"
                    or type(record.update) ~= "table"
                )
            then
                return false
            elseif
                record.type ~= "meta"
                and record.type ~= "message"
                and record.type ~= "tool_call_update"
            then
                return false
            end
        end
    end
    return has_record
end

--- @param jsonl string
--- @return boolean valid
validate_event_jsonl = function(jsonl)
    if not validate_jsonl(jsonl) then
        return false
    end
    for _, line in ipairs(vim.split(jsonl, "\n", { plain = true })) do
        if line:match("%S") then
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= "table" or record.type == "meta" then
                return false
            end
        end
    end
    return true
end

--- @param src string
--- @param dst string
--- @return boolean success
--- @return string|nil err
local function copy_file(src, dst)
    local source, source_err = io.open(src, "rb")
    if not source then
        return false, tostring(source_err)
    end
    local content = source:read("*a")
    source:close()
    if not content then
        return false, "Failed to read backup source"
    end

    local dir = vim.fn.fnamemodify(dst, ":h")
    if vim.fn.isdirectory(dir) == 0 then
        local ok, err = FileSystem.mkdirp(dir)
        if not ok then
            return false, err
        end
    end

    local destination, destination_err = io.open(dst, "wb")
    if not destination then
        return false, tostring(destination_err)
    end
    local ok, write_err = destination:write(content)
    destination:close()
    if not ok then
        return false, tostring(write_err)
    end
    return true, nil
end

--- @param sessions_root string
--- @param project_folder string
--- @param filename string
--- @return string[] backup_paths
local function find_preserved_json_backup(
    sessions_root,
    project_folder,
    filename
)
    local backups = {}
    for backup_root_order, backup_root_name in ipairs({
        "_legacy_backups",
        BACKUP_DIR_NAME,
    }) do
        local backup_root = vim.fs.joinpath(sessions_root, backup_root_name)
        if vim.fn.isdirectory(backup_root) == 1 then
            for timestamp, file_type in vim.fs.dir(backup_root) do
                if file_type == "directory" then
                    local backup_path = vim.fs.joinpath(
                        backup_root,
                        timestamp,
                        project_folder,
                        filename
                    )
                    if vim.uv.fs_stat(backup_path) ~= nil then
                        table.insert(backups, {
                            path = backup_path,
                            timestamp = timestamp,
                            root_order = backup_root_order,
                        })
                    end
                end
            end
        end
    end

    table.sort(backups, function(a, b)
        if a.timestamp == b.timestamp then
            return a.root_order < b.root_order
        end
        return a.timestamp > b.timestamp
    end)

    local backup_paths = {}
    for _, backup in ipairs(backups) do
        table.insert(backup_paths, backup.path)
    end
    return backup_paths
end

--- @param data table|nil
--- @param session_id string
--- @return agentic.ui.ChatHistory.SessionMeta|nil metadata
local function metadata_from_legacy_data(data, session_id)
    if type(data) ~= "table" then
        return nil
    end
    local created_at, updated_at = normalize_session_times(data)
    if created_at <= 0 or updated_at <= 0 then
        return nil
    end
    --- @type agentic.ui.ChatHistory.SessionMeta
    local metadata = {
        session_id = resolve_session_id(data, session_id),
        acp_session_id = data.acp_session_id,
        title = data.title,
        created_at = created_at,
        updated_at = updated_at,
        message_count = data.message_count,
    }
    return metadata
end

--- @param sessions_root string
--- @param project_folder string
--- @param session_id string
--- @return agentic.ui.ChatHistory.SessionMeta|nil metadata
local function find_legacy_metadata(sessions_root, project_folder, session_id)
    local project_path = vim.fs.joinpath(sessions_root, project_folder)
    local candidates = {
        vim.fs.joinpath(project_path, session_id .. ".json"),
        vim.fs.joinpath(project_path, session_id .. ".meta.json"),
    }
    local backup_json_paths = find_preserved_json_backup(
        sessions_root,
        project_folder,
        session_id .. ".json"
    )
    vim.list_extend(candidates, backup_json_paths)
    local backup_metadata_paths = find_preserved_json_backup(
        sessions_root,
        project_folder,
        session_id .. ".meta.json"
    )
    vim.list_extend(candidates, backup_metadata_paths)
    for _, path in ipairs(candidates) do
        local data = read_json_file_sync(path)
        local metadata = metadata_from_legacy_data(data, session_id)
        if metadata then
            return metadata
        end
    end
    return nil
end

--- @param backup_path string
--- @param session_id string
--- @return string|nil jsonl
local function recover_jsonl_from_backup(backup_path, session_id)
    local messages_data = read_json_file_sync(backup_path)
    if not is_legacy_storage_data(messages_data) then
        return nil
    end
    --- @cast messages_data table
    local created_at, updated_at = normalize_session_times(messages_data)
    return encode_jsonl(messages_data.messages, {
        session_id = resolve_session_id(messages_data, session_id),
        acp_session_id = messages_data.acp_session_id,
        title = messages_data.title or "",
        created_at = created_at,
        updated_at = updated_at,
        message_count = #messages_data.messages,
    })
end

--- @param path string
local function remove_if_exists(path)
    if vim.uv.fs_stat(path) ~= nil then
        os.remove(path)
    end
end

--- @param path string
--- @return boolean empty
local function is_empty_file(path)
    local stat = vim.uv.fs_stat(path)
    return stat ~= nil and stat.type == "file" and stat.size == 0
end

--- @param folder_name string
--- @return boolean ignored
local function is_backup_or_quarantine_folder(folder_name)
    local normalized = folder_name:lower()
    return normalized:find("backup", 1, true) ~= nil
        or normalized:find("quarantine", 1, true) ~= nil
end

--- @param backup_dir string
--- @param project_folder string
--- @param messages_path string
--- @param metadata_path string
--- @param filename string
--- @param session_id string
--- @return boolean success
local function backup_legacy_files(
    backup_dir,
    project_folder,
    messages_path,
    metadata_path,
    filename,
    session_id
)
    local backup_project = vim.fs.joinpath(backup_dir, project_folder)
    local backup_messages = vim.fs.joinpath(backup_project, filename)
    local backup_ok = copy_file(messages_path, backup_messages)
    local backup_meta_ok = true
    if vim.uv.fs_stat(metadata_path) ~= nil then
        backup_meta_ok = copy_file(
            metadata_path,
            vim.fs.joinpath(backup_project, session_id .. ".meta.json")
        )
    end

    return backup_ok and backup_meta_ok
end

--- @return agentic.ui.ChatHistory.MigrationResult result
function ChatHistory.migrate_all_sessions_to_jsonl()
    local sessions_root = ChatHistory.get_sessions_root()
    local backup_dir_base = vim.fs.joinpath(
        sessions_root,
        BACKUP_DIR_NAME,
        os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(vim.uv.hrtime())
    )
    local backup_dir = backup_dir_base
    local backup_suffix = 0
    while vim.fn.isdirectory(backup_dir) == 1 do
        backup_suffix = backup_suffix + 1
        backup_dir = backup_dir_base .. "_" .. backup_suffix
    end
    --- @type agentic.ui.ChatHistory.MigrationResult
    local result = {
        backup_dir = backup_dir,
        migrated = 0,
        recovered = 0,
        skipped = 0,
        failed = 0,
        errors = {},
    }

    if vim.fn.isdirectory(sessions_root) == 0 then
        return result
    end

    for project_folder, file_type in vim.fs.dir(sessions_root) do
        if
            file_type == "directory"
            and project_folder ~= BACKUP_DIR_NAME
            and not is_backup_or_quarantine_folder(project_folder)
        then
            local project_path = vim.fs.joinpath(sessions_root, project_folder)
            for filename, child_type in vim.fs.dir(project_path) do
                if child_type == "file" then
                    local jsonl_id = filename:match("^(.*)%.jsonl$")
                    local session_id = filename:match("^(.*)%.json$")
                    if jsonl_id then
                        local jsonl_path =
                            vim.fs.joinpath(project_path, filename)
                        local jsonl_content = read_file_sync(jsonl_path)
                        if jsonl_content and validate_jsonl(jsonl_content) then
                            result.skipped = result.skipped + 1
                        else
                            local backup_paths = find_preserved_json_backup(
                                sessions_root,
                                project_folder,
                                jsonl_id .. ".json"
                            )
                            local recovered_jsonl = nil
                            local active_legacy_path = vim.fs.joinpath(
                                project_path,
                                jsonl_id .. ".json"
                            )
                            local recovery_paths = { active_legacy_path }
                            vim.list_extend(recovery_paths, backup_paths)
                            for _, candidate_path in ipairs(recovery_paths) do
                                local candidate_jsonl =
                                    recover_jsonl_from_backup(
                                        candidate_path,
                                        jsonl_id
                                    )
                                if candidate_jsonl then
                                    recovered_jsonl = candidate_jsonl
                                    break
                                end
                            end
                            local recovery_backup_path = vim.fs.joinpath(
                                backup_dir,
                                project_folder,
                                filename
                            )
                            if
                                type(recovered_jsonl) == "string"
                                and copy_file(jsonl_path, recovery_backup_path)
                            then
                                local tmp_path = jsonl_path .. ".tmp"
                                local write_ok =
                                    write_file_sync(tmp_path, recovered_jsonl)
                                if
                                    write_ok
                                    and validate_jsonl(
                                        assert(read_file_sync(tmp_path))
                                    )
                                    and os.rename(tmp_path, jsonl_path)
                                then
                                    result.recovered = result.recovered + 1
                                else
                                    remove_if_exists(tmp_path)
                                    result.failed = result.failed + 1
                                    table.insert(
                                        result.errors,
                                        jsonl_path .. ": recovery failed"
                                    )
                                end
                            else
                                result.failed = result.failed + 1
                                table.insert(
                                    result.errors,
                                    jsonl_path
                                        .. ": recovery backup unavailable"
                                )
                            end
                        end
                    elseif
                        session_id and not filename:match("%.meta%.json$")
                    then
                        local messages_path =
                            vim.fs.joinpath(project_path, filename)
                        local metadata_path = vim.fs.joinpath(
                            project_path,
                            session_id .. ".meta.json"
                        )
                        local jsonl_path = vim.fs.joinpath(
                            project_path,
                            session_id .. ".jsonl"
                        )

                        if vim.uv.fs_stat(jsonl_path) ~= nil then
                            local jsonl_content = read_file_sync(jsonl_path)
                            local metadata_data =
                                read_json_file_sync(metadata_path)
                            local metadata_ok = true
                            local metadata_to_write = nil
                            if
                                jsonl_content
                                and validate_event_jsonl(jsonl_content)
                                and not metadata_from_legacy_data(
                                    metadata_data,
                                    session_id
                                )
                            then
                                local metadata = find_legacy_metadata(
                                    sessions_root,
                                    project_folder,
                                    session_id
                                )
                                metadata_ok = metadata ~= nil
                                if metadata_ok and metadata then
                                    metadata_to_write =
                                        vim.json.encode(metadata)
                                end
                            end
                            if
                                metadata_ok
                                and backup_legacy_files(
                                    backup_dir,
                                    project_folder,
                                    messages_path,
                                    metadata_path,
                                    filename,
                                    session_id
                                )
                            then
                                if metadata_to_write then
                                    metadata_ok = write_file_atomic_sync(
                                        metadata_path,
                                        metadata_to_write
                                    ) and decode_session_metadata(
                                        metadata_to_write,
                                        session_id
                                    ) ~= nil
                                end
                                if metadata_ok then
                                    remove_if_exists(messages_path)
                                    if not metadata_to_write then
                                        remove_if_exists(metadata_path)
                                    end
                                    result.migrated = result.migrated + 1
                                else
                                    result.failed = result.failed + 1
                                    table.insert(
                                        result.errors,
                                        messages_path
                                            .. ": metadata write failed"
                                    )
                                end
                            else
                                result.failed = result.failed + 1
                                table.insert(
                                    result.errors,
                                    messages_path .. ": backup failed"
                                )
                            end
                        else
                            local messages_data, messages_err =
                                read_json_file_sync(messages_path)
                            local metadata_data =
                                read_json_file_sync(metadata_path)
                            local messages = nil
                            local metadata = nil

                            if
                                is_empty_file(messages_path)
                                and (
                                    vim.uv.fs_stat(metadata_path) == nil
                                    or is_empty_file(metadata_path)
                                )
                            then
                                messages = {}
                                metadata = {
                                    session_id = session_id,
                                    title = "",
                                    created_at = 0,
                                    updated_at = 0,
                                    message_count = 0,
                                }
                            elseif is_legacy_storage_data(messages_data) then
                                --- @cast messages_data table
                                messages = messages_data.messages
                                local created_at, updated_at =
                                    normalize_session_times(messages_data)
                                metadata = {
                                    session_id = resolve_session_id(
                                        messages_data,
                                        session_id
                                    ),
                                    acp_session_id = messages_data.acp_session_id,
                                    title = messages_data.title or "",
                                    created_at = created_at,
                                    updated_at = updated_at,
                                    message_count = #messages,
                                }
                            elseif
                                type(messages_data) == "table"
                                and type(messages_data.messages) == "table"
                                and type(metadata_data) == "table"
                            then
                                messages = messages_data.messages
                                local created_at, updated_at =
                                    normalize_session_times(metadata_data)
                                metadata = {
                                    session_id = resolve_session_id(
                                        metadata_data,
                                        session_id
                                    ),
                                    acp_session_id = metadata_data.acp_session_id,
                                    title = metadata_data.title or "",
                                    created_at = created_at,
                                    updated_at = updated_at,
                                    message_count = #messages,
                                }
                            end

                            local jsonl = messages
                                    and metadata
                                    and encode_jsonl(messages, metadata)
                                or nil
                            if not jsonl or not validate_jsonl(jsonl) then
                                result.failed = result.failed + 1
                                if
                                    backup_legacy_files(
                                        backup_dir,
                                        project_folder,
                                        messages_path,
                                        metadata_path,
                                        filename,
                                        session_id
                                    )
                                then
                                    remove_if_exists(messages_path)
                                    remove_if_exists(metadata_path)
                                end
                                table.insert(
                                    result.errors,
                                    messages_path
                                        .. ": "
                                        .. (messages_err or "invalid session")
                                )
                            else
                                if
                                    not backup_legacy_files(
                                        backup_dir,
                                        project_folder,
                                        messages_path,
                                        metadata_path,
                                        filename,
                                        session_id
                                    )
                                then
                                    result.failed = result.failed + 1
                                    table.insert(
                                        result.errors,
                                        messages_path .. ": backup failed"
                                    )
                                else
                                    local tmp_path = jsonl_path .. ".tmp"
                                    local write_ok =
                                        write_file_sync(tmp_path, jsonl)
                                    if
                                        write_ok
                                        and validate_jsonl(
                                            assert(read_file_sync(tmp_path))
                                        )
                                    then
                                        local rename_ok =
                                            os.rename(tmp_path, jsonl_path)
                                        if rename_ok then
                                            remove_if_exists(messages_path)
                                            remove_if_exists(metadata_path)
                                            result.migrated = result.migrated
                                                + 1
                                        else
                                            remove_if_exists(tmp_path)
                                            result.failed = result.failed + 1
                                            table.insert(
                                                result.errors,
                                                jsonl_path .. ": rename failed"
                                            )
                                        end
                                    else
                                        remove_if_exists(tmp_path)
                                        result.failed = result.failed + 1
                                        table.insert(
                                            result.errors,
                                            jsonl_path .. ": write failed"
                                        )
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end
    end

    return result
end

ChatHistory.migrate_all_legacy_sessions =
    ChatHistory.migrate_all_sessions_to_jsonl

--- @param content string
--- @param session_id string
--- @return string|nil messages_jsonl
--- @return table|nil metadata
local function split_mixed_jsonl(content, session_id)
    local events = {}
    local metadata = nil
    for _, line in ipairs(vim.split(content, "\n", { plain = true })) do
        if line:match("%S") then
            local ok, record = pcall(vim.json.decode, line)
            if not ok or type(record) ~= "table" then
                return nil, nil
            end
            if record.type == "meta" then
                if
                    type(record.title) ~= "string"
                    or type(record.created_at) ~= "number"
                    or type(record.updated_at) ~= "number"
                then
                    return nil, nil
                end
                metadata = {
                    session_id = resolve_session_id(record, session_id),
                    acp_session_id = record.acp_session_id,
                    title = record.title,
                    created_at = record.created_at,
                    updated_at = record.updated_at,
                    message_count = record.message_count,
                }
            elseif
                (record.type == "message" and is_valid_message(record.message))
                or (
                    record.type == "tool_call_update"
                    and type(record.tool_call_id) == "string"
                    and type(record.update) == "table"
                )
            then
                table.insert(events, record)
            else
                return nil, nil
            end
        end
    end
    if not metadata then
        return nil, nil
    end
    local lines = {}
    for _, event in ipairs(events) do
        local ok, encoded = pcall(vim.json.encode, event)
        if not ok then
            return nil, nil
        end
        table.insert(lines, encoded)
    end
    metadata.message_count = metadata.message_count or 0
    return table.concat(lines, "\n"), metadata
end

--- @return agentic.ui.ChatHistory.MigrationResult result
function ChatHistory.migrate_all_sessions_to_split()
    local sessions_root = ChatHistory.get_sessions_root()
    local backup_dir = vim.fs.joinpath(
        sessions_root,
        BACKUP_DIR_NAME,
        os.date("%Y%m%d_%H%M%S") .. "_" .. tostring(vim.uv.hrtime())
    )
    --- @type agentic.ui.ChatHistory.MigrationResult
    local result = {
        backup_dir = backup_dir,
        migrated = 0,
        recovered = 0,
        skipped = 0,
        failed = 0,
        errors = {},
    }
    if vim.fn.isdirectory(sessions_root) == 0 then
        return result
    end

    for project_folder, project_type in vim.fs.dir(sessions_root) do
        if
            project_type == "directory"
            and project_folder ~= BACKUP_DIR_NAME
            and not is_backup_or_quarantine_folder(project_folder)
        then
            local project_path = vim.fs.joinpath(sessions_root, project_folder)
            for filename, file_type in vim.fs.dir(project_path) do
                local session_id = filename:match("^(.*)%.jsonl$")
                if file_type == "file" and session_id then
                    local jsonl_path = vim.fs.joinpath(project_path, filename)
                    local content = read_file_sync(jsonl_path)
                    local metadata_path = vim.fs.joinpath(
                        project_path,
                        session_id .. ".meta.json"
                    )
                    local metadata_content = read_file_sync(metadata_path)
                    local metadata_data = read_json_file_sync(metadata_path)
                    local already_split = metadata_content ~= nil
                        and content ~= nil
                        and not content:match('"type"%s*:%s*"meta"')
                        and type(metadata_data) == "table"
                        and type(metadata_data.session_id) == "string"
                        and metadata_data.session_id ~= ""
                        and type(metadata_data.title) == "string"
                        and type(metadata_data.created_at) == "number"
                        and type(metadata_data.updated_at) == "number"
                        and metadata_from_legacy_data(metadata_data, session_id) ~= nil
                        and validate_event_jsonl(content)
                    if already_split then
                        result.skipped = result.skipped + 1
                    else
                        local messages_jsonl, metadata =
                            split_mixed_jsonl(content or "", session_id)
                        if
                            not messages_jsonl
                            and content
                            and validate_event_jsonl(content)
                        then
                            metadata = find_legacy_metadata(
                                sessions_root,
                                project_folder,
                                session_id
                            )
                            if metadata then
                                messages_jsonl = content
                            end
                        end
                        if not messages_jsonl or not metadata then
                            result.skipped = result.skipped + 1
                        else
                            if
                                type(metadata_data) == "table"
                                and type(metadata_data.session_id) == "string"
                                and metadata_data.session_id ~= ""
                                and type(metadata_data.title) == "string"
                                and type(metadata_data.created_at) == "number"
                                and type(metadata_data.updated_at)
                                    == "number"
                            then
                                local external_metadata =
                                    metadata_from_legacy_data(
                                        metadata_data,
                                        session_id
                                    )
                                if external_metadata then
                                    metadata = vim.tbl_extend(
                                        "force",
                                        metadata,
                                        external_metadata
                                    )
                                end
                            end
                            local backup_project =
                                vim.fs.joinpath(backup_dir, project_folder)
                            local backup_jsonl =
                                vim.fs.joinpath(backup_project, filename)
                            local backup_ok =
                                copy_file(jsonl_path, backup_jsonl)
                            if metadata_content then
                                backup_ok = backup_ok
                                    and copy_file(
                                        metadata_path,
                                        vim.fs.joinpath(
                                            backup_project,
                                            session_id .. ".meta.json"
                                        )
                                    )
                            end
                            if not backup_ok then
                                result.failed = result.failed + 1
                                table.insert(
                                    result.errors,
                                    jsonl_path .. ": backup failed"
                                )
                            else
                                local encoded_metadata =
                                    vim.json.encode(metadata)
                                local messages_ok, messages_err =
                                    write_file_atomic_sync(
                                        jsonl_path,
                                        messages_jsonl
                                    )
                                local metadata_ok, metadata_err =
                                    write_file_atomic_sync(
                                        metadata_path,
                                        encoded_metadata
                                    )
                                if messages_ok and metadata_ok then
                                    result.migrated = result.migrated + 1
                                else
                                    result.failed = result.failed + 1
                                    table.insert(
                                        result.errors,
                                        jsonl_path
                                            .. ": "
                                            .. (messages_err or metadata_err)
                                    )
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return result
end

return ChatHistory
