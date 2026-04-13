local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Logger = require("agentic.utils.logger")
local SessionRegistry = require("agentic.session_registry")

--- @alias agentic.RestoreMode "fork" | "continue"

--- @class agentic.SessionRestore
local SessionRestore = {}

--- Lazily load fzf-lua module
--- @return table|nil fzf_lua module or nil if not available
local function load_fzf_lua()
    local ok, fzf = pcall(require, "fzf-lua")
    if not ok then
        return nil
    end
    return fzf
end

--- Load selected session, cancel current, and restore with given mode
--- @param session_id string
--- @param tab_page_id integer
--- @param restore_mode agentic.RestoreMode
local function do_restore(session_id, tab_page_id, restore_mode)
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

            session:restore_from_history(history, {
                replace_session = restore_mode == "continue",
            })

            session.widget:show()
        end)
    end)
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
    local current_items = {}

    --- @param fzf_cb fun(entry: string|nil)
    local function contents(fzf_cb)
        current_items = build_items()
        for i, item in ipairs(current_items) do
            fzf_cb(string.format("%d. %s", i, item.display))
        end
        fzf_cb() -- EOF
    end

    local actions = {
        ["default"] = function(selected)
            if not selected or #selected == 0 then
                on_choice(nil)
                return
            end

            local idx = tonumber(selected[1]:match("^(%d+)%."))
            if idx and current_items[idx] then
                on_choice(current_items[idx])
                return
            end
            on_choice(nil)
        end,
    }

    local fzf_opts = {}

    if on_delete then
        actions["ctrl-x"] = {
            fn = function(selected)
                if not selected or #selected == 0 then
                    return
                end

                local idx = tonumber(selected[1]:match("^(%d+)%."))
                if idx and current_items[idx] then
                    on_delete(current_items[idx])
                end
            end,
            reload = true,
        }
        fzf_opts["--header"] = "ctrl-x: delete session"
    end

    fzf.fzf_exec(contents, {
        prompt = "Select session to restore> ",
        winopts = {
            height = 0.4,
            width = 0.6,
            row = 0.5,
            col = 0.5,
        },
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

        SessionRestore.show_restore_mode_picker(function(mode)
            if mode then
                do_restore(choice.session_id, tab_page_id, mode)
            end
        end)
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

--- Show restore mode picker (fork vs continue). Reusable from any entry point.
--- @param callback fun(mode: agentic.RestoreMode|nil)
function SessionRestore.show_restore_mode_picker(callback)
    local fzf = load_fzf_lua()

    --- @type {id: agentic.RestoreMode, display: string}[]
    local options = {
        { id = "continue", display = "Continue session" },
        { id = "fork", display = "Fork as new session" },
    }

    if not fzf then
        vim.ui.select(options, {
            prompt = "Restore mode:",
            format_item = function(item)
                return item.display
            end,
        }, function(choice)
            callback(choice and choice.id or nil)
        end)
        return
    end

    local display_list = {}
    for _, opt in ipairs(options) do
        table.insert(display_list, opt.display)
    end

    fzf.fzf_exec(display_list, {
        prompt = "Restore mode> ",
        winopts = {
            height = 0.15,
            width = 0.4,
            row = 0.5,
            col = 0.5,
        },
        actions = {
            ["default"] = function(selected)
                if not selected or #selected == 0 then
                    callback(nil)
                    return
                end

                for _, opt in ipairs(options) do
                    if opt.display == selected[1] then
                        callback(opt.id)
                        return
                    end
                end
                callback(nil)
            end,
        },
    })
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
            --- @type agentic.ui.MessageWriter.ToolCallBlock
            local tool_block = {
                tool_call_id = msg.tool_call_id,
                kind = msg.kind,
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
