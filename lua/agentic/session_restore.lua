--- @diagnostic disable: param-type-mismatch
local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Lazily load fzf-lua module
--- @return table|nil fzf_lua module or nil if not available
local function load_fzf_lua()
    local ok, fzf = pcall(require, "fzf-lua")
    if not ok then
        return nil
    end
    --- @diagnostic disable-next-line: return-type-mismatch
    return fzf
end

--- Load selected session, cancel current, and restore in continue mode
--- @param session_id string
--- @param tab_page_id integer
local function do_restore(session_id, tab_page_id)
    ChatHistory.load(session_id, function(history, err)
        if err or not history then
            Logger.notify(
                "Failed to load session: " .. (err or "unknown error"),
                vim.log.levels.WARN
            )
            return
        end

        SessionRegistry.get_session_for_tab_page(tab_page_id, function(session)
            -- Always cancel current session
            if session.session_id then
                session.agent:cancel_session(session.session_id)
            end
            session.widget:clear()

            session:restore_from_history(history, { replace_session = true })

            session.widget:show()
        end)
    end)
end

--- @param parsed table|nil
--- @param fallback_title string
--- @return string[] lines
--- @return string preview_title
local function build_preview_lines(parsed, fallback_title)
    --- @param output string[]
    --- @param text string|nil
    local function append_text_lines(output, text)
        local chunks = vim.split(text or "", "\n", { plain = true })
        for _, chunk in ipairs(chunks) do
            table.insert(output, chunk)
        end
    end

    local lines = {
        "# Session Preview",
        "",
    }
    if not parsed then
        table.insert(lines, "_Unable to load session preview_")
        return lines, fallback_title
    end

    local title = (parsed.title or ""):gsub("\n", " ")
    if title == "" then
        title = fallback_title
    end
    table.insert(lines, "## " .. title)
    table.insert(lines, "")

    for _, msg in ipairs(parsed.messages or {}) do
        if msg.type == "user" then
            local timestamp_str = msg.timestamp
                    and os.date("%Y-%m-%d %H:%M:%S", msg.timestamp)
                or os.date("%Y-%m-%d %H:%M:%S")
            table.insert(
                lines,
                string.format("##  User - %s", timestamp_str)
            )
            table.insert(lines, "")
            append_text_lines(lines, msg.text)
            table.insert(lines, "")
            table.insert(
                lines,
                "### 󱚠 Agent - " .. (msg.provider_name or "Unknown")
            )
            table.insert(lines, "")
        elseif msg.type == "agent" then
            append_text_lines(lines, msg.text)
            table.insert(lines, "")
        end
    end

    --- @diagnostic disable-next-line: return-type-mismatch
    return lines, title
end

--- @param session_id string
--- @return table|nil
local function load_session_from_disk_sync(session_id)
    local path = ChatHistory.get_file_path(session_id)
    if vim.fn.filereadable(path) == 0 then
        return nil
    end

    local content = vim.fn.readfile(path)
    if #content == 0 then
        return nil
    end

    local ok, parsed = pcall(vim.json.decode, table.concat(content, "\n"))
    if not ok or not parsed then
        return nil
    end

    return parsed
end

--- @param fixed_session_id string|nil
--- @return table
local function create_session_previewer(fixed_session_id)
    --- @diagnostic disable-next-line: unresolved-require
    local builtin = require("fzf-lua.previewer.builtin")
    local previewer = builtin.base:extend()

    function previewer:new(o, opts, fzf_win)
        self.super.new(self, o, opts, fzf_win)
        setmetatable(self, previewer)
        return self
    end

    function previewer:populate_preview_buf(entry_str)
        local session_id = fixed_session_id
        if not session_id then
            session_id = entry_str:match("^([^\t]+)")
        end

        local buf = self:get_tmp_buffer()
        vim.bo[buf].filetype = "markdown"

        if not session_id or session_id == "" then
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
                "# Session Preview",
                "",
                "_Unable to determine session id_",
            })
            self:set_preview_buf(buf)
            self.win:update_preview_title("Session preview")
            return
        end

        local parsed = load_session_from_disk_sync(session_id)
        local lines, title =
            build_preview_lines(parsed, "Session " .. session_id)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
        self:set_preview_buf(buf)
        if self.win and self.win.update_preview_title then
            self.win:update_preview_title(title)
        end
    end

    return previewer
end

--- Show session picker using fzf-lua (with fallback to vim.ui.select)
--- @param build_items fun(): table[] Function that returns current session items
--- @param on_choice fun(choice: table|nil) Callback when user selects an item
--- @param on_delete fun(choice: table)|nil Callback when user requests deletion
local function show_fzf_picker(build_items, on_choice, on_delete)
    local fzf = load_fzf_lua()

    if not fzf then
        -- Fallback to vim.ui.select if fzf-lua is not available
        local items = build_items()
        vim.ui.select(items, {
            prompt = "Select session to restore:",
            format_item = function(item)
                return item.display
            end,
        }, on_choice)
        return
    end

    -- Shared state: rebuilt each time the content function runs (initial + reload)
    local current_items_by_session_id = {}

    --- @param fzf_cb fun(entry: string|nil)
    local function contents(fzf_cb)
        local current_items = build_items()
        current_items_by_session_id = {}
        for _, item in ipairs(current_items) do
            current_items_by_session_id[item.session_id] = item
            fzf_cb(string.format("%s\t%s", item.session_id, item.display))
        end
        fzf_cb() -- EOF
    end

    --- @param selected string[]|nil
    --- @return table|nil
    local function get_selected(selected)
        if not selected or #selected == 0 then
            return nil
        end

        --- @diagnostic disable-next-line: need-check-nil
        local session_id = selected[1]:match("^([^\t]+)\t")
        if not session_id then
            return nil
        end

        local item = current_items_by_session_id[session_id]
        if not item then
            return nil
        end

        return item
    end

    local actions = {
        ["default"] = function(selected)
            local item = get_selected(selected)
            if item then
                on_choice(item)
                return
            end
            on_choice(nil)
        end,
    }

    local fzf_opts = {
        ["--delimiter"] = "\t",
        ["--with-nth"] = "2..",
    }

    if on_delete then
        actions["ctrl-x"] = {
            fn = function(selected)
                local item = get_selected(selected)
                if item then
                    on_delete(item)
                end
            end,
            reload = true,
        }
    end

    local header_lines = {
        "enter: continue selected session",
    }

    if on_delete then
        table.insert(header_lines, "ctrl-x: delete session")
    end

    fzf_opts["--header"] = table.concat(header_lines, "\n")

    fzf.fzf_exec(contents, {
        prompt = "Select session to restore> ",
        winopts = {
            height = 0.85,
            width = 0.9,
            row = 0.5,
            col = 0.5,
        },
        previewer = function()
            return create_session_previewer(nil)
        end,
        fzf_opts = fzf_opts,
        actions = actions,
    })
end

--- Build session items from disk. list_sessions is synchronous despite
--- the callback API, so the returned table is populated before this returns.
--- @return table[] items
local function build_session_items()
    local items = {}
    ChatHistory.list_sessions(function(sessions)
        for _, s in ipairs(sessions) do
            local date = os.date("%Y-%m-%d %H:%M", s.timestamp or 0)
            local title = (s.title or "(no title)"):gsub("\n", " ")

            table.insert(items, {
                display = string.format("%s - %s", date, title),
                session_id = s.session_id,
            })
        end
    end)
    return items
end

--- Show session picker and restore selected session
--- @param tab_page_id integer
function SessionRestore.show_picker(tab_page_id)
    local initial_items = build_session_items()
    if #initial_items == 0 then
        Logger.notify("No saved sessions found", vim.log.levels.INFO)
        return
    end

    show_fzf_picker(build_session_items, function(choice)
        if not choice then
            return
        end

        do_restore(choice.session_id, tab_page_id)
    end, function(choice)
        ChatHistory.delete_session(choice.session_id, function(err)
            if err then
                Logger.notify(
                    "Failed to delete session: " .. err,
                    vim.log.levels.WARN
                )
                return
            end
            Logger.notify("Session deleted", vim.log.levels.INFO)
        end)
    end)
end

--- Replay stored messages to the UI
--- @param writer agentic.ui.MessageWriter
--- @param messages agentic.ui.ChatHistory.Message[]
function SessionRestore.replay_messages(writer, messages)
    for _, msg in ipairs(messages) do
        if msg.type == "user" then
            -- Format user message for display with original timestamp
            local timestamp_str = msg.timestamp
                    and os.date("%Y-%m-%d %H:%M:%S", msg.timestamp)
                or os.date("%Y-%m-%d %H:%M:%S")
            local message_lines = {
                string.format("##  User - %s", timestamp_str),
                "",
                msg.text,
                "\n\n### 󱚠 Agent - "
                    .. (msg.provider_name or "Unknown provider"),
            }
            local user_message =
                ACPPayloads.generate_user_message(message_lines)
            writer:record_prompt_position()
            writer:write_message(user_message)
        elseif msg.type == "agent" then
            --- @diagnostic disable-next-line: param-type-mismatch
            local agent_message = ACPPayloads.generate_agent_message(msg.text)
            writer:write_message(agent_message)
        elseif msg.type == "thought" then
            --- @type agentic.acp.AgentThoughtChunk
            local thought_chunk = {
                sessionUpdate = "agent_thought_chunk",
                content = { type = "text", text = msg.text },
            }
            writer:write_message_chunk(thought_chunk)
        elseif msg.type == "tool_call" then
            local tool_call_id = msg.tool_call_id or ""
            local kind = msg.kind or "execute"

            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local tool_block = {
                tool_call_id = tool_call_id,
                kind = kind,
                argument = msg.argument or "",
                status = msg.status,
                body = msg.body,
                diff = msg.diff,
            }
            writer:write_tool_call_block(tool_block)
        end
    end
end

return SessionRestore
