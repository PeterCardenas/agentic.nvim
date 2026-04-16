--- @diagnostic disable: unnecessary-if, assign-type-mismatch, param-type-mismatch
-- The session manager class glues together the Chat widget, the agent instance, and the message writer.
-- It is responsible for managing the session state, routing messages between components, and handling user interactions.
-- When the user creates a new session, the SessionManager should be responsible for cleaning the existing session (if any) and initializing a new one.
-- When the user switches the provider, the SessionManager should handle the transition smoothly,
-- ensuring that the new session is properly set up and all the previous messages are sent to the new agent provider without duplicating them in the chat widget

local ACPPayloads = require("agentic.acp.acp_payloads")
local ChatHistory = require("agentic.ui.chat_history")
local Config = require("agentic.config")
local DiffPreview = require("agentic.ui.diff_preview")
local DiagnosticsList = require("agentic.ui.diagnostics_list")
local FileSystem = require("agentic.utils.file_system")
local Logger = require("agentic.utils.logger")
local SlashCommands = require("agentic.acp.slash_commands")

--- @class agentic._SessionManagerPrivate
local P = {}

--- Tool call kinds that mutate files on disk.
--- When these complete, buffers must be reloaded via checktime.
local FILE_MUTATING_KINDS = {
    edit = true,
    create = true,
    write = true,
    delete = true,
    move = true,
}

--- Format elapsed duration from a high-resolution start time to a human-readable string
--- @param start_hrtime number|nil
--- @return string duration
function P.format_duration(start_hrtime)
    if not start_hrtime then
        return "unknown"
    end

    local elapsed_ns = vim.uv.hrtime() - start_hrtime
    local elapsed_s = elapsed_ns / 1e9

    if elapsed_s < 60 then
        return string.format("%.1fs", elapsed_s)
    end

    local minutes = math.floor(elapsed_s / 60)
    local seconds = elapsed_s - (minutes * 60)

    if minutes < 60 then
        return string.format("%dm %ds", minutes, math.floor(seconds))
    end

    local hours = math.floor(minutes / 60)
    local remaining_minutes = minutes - (hours * 60)
    return string.format("%dh %dm", hours, remaining_minutes)
end

--- Safely invoke a user-configured hook
--- @param hook_name "on_prompt_submit" | "on_response_complete" | "on_session_update" | "on_file_edit"
--- @param data table
function P.invoke_hook(hook_name, data)
    local hook = Config.hooks and Config.hooks[hook_name]

    if hook and type(hook) == "function" then
        vim.schedule(function()
            local ok, err = pcall(hook, data)
            if not ok then
                Logger.debug(
                    string.format("Hook '%s' error: %s", hook_name, err)
                )
            end

            -- Force statusline/winbar redraw so hooks that update
            -- statusline variables take effect immediately.
            vim.cmd("redrawstatus!")
        end)
    end
end

--- @class agentic.SessionManager
--- @field session_id? string
--- @field tab_page_id integer
--- @field _is_first_message boolean Whether this is the first message in the session, used to add system info only once
--- @field is_generating boolean
--- @field _turn_start_time? number High-resolution timestamp (from vim.uv.hrtime) when the current turn started
--- @field _pending_input? string Prompt text queued while session was initializing
--- @field widget agentic.ui.ChatWidget
--- @field agent agentic.acp.ACPClient
--- @field message_writer agentic.ui.MessageWriter
--- @field permission_manager agentic.ui.PermissionManager
--- @field status_animation agentic.ui.StatusAnimation
--- @field file_list agentic.ui.FileList
--- @field code_selection agentic.ui.CodeSelection
--- @field diagnostics_list agentic.ui.DiagnosticsList
--- @field config_options agentic.acp.AgentConfigOptions
--- @field todo_list agentic.ui.TodoList
--- @field chat_history agentic.ui.ChatHistory
--- @field chat_folds agentic.ui.ChatFolds
--- @field _history_to_send? agentic.ui.ChatHistory.Message[] Messages to prepend on next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
--- @field _replace_session boolean When true, preserve loaded session identity on next submit (continue mode)
local SessionManager = {}
SessionManager.__index = SessionManager

--- Generate the welcome header for a new session
--- @param provider_name string
--- @param session_id string|nil
--- @return string header
function SessionManager._generate_welcome_header(provider_name, session_id)
    local timestamp = os.date("%Y-%m-%d %H:%M:%S")
    return string.format(
        "# Agentic - %s - %s\n- %s\n--- --",
        provider_name,
        session_id or "unknown",
        timestamp
    )
end

--- @param tab_page_id integer
function SessionManager:new(tab_page_id)
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local FilePicker = require("agentic.ui.file_picker")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")

    self = setmetatable({
        session_id = nil,
        tab_page_id = tab_page_id,
        _is_first_message = true,
        is_generating = false,
        _restoring = false,
        _replace_session = false,
    }, self)

    local agent = AgentInstance.get_instance(Config.provider, function(_client)
        vim.schedule(function()
            -- Skip auto-new_session if restore_from_history was called
            if not self._restoring then
                self:new_session()
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent

    self.chat_history = ChatHistory:new()

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.widget.message_writer = self.message_writer
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.permission_manager = PermissionManager:new(self.message_writer)

    local ChatFolds = require("agentic.ui.chat_folds")
    self.chat_folds = ChatFolds:new(self.widget.buf_nrs.chat, tab_page_id)
    self.message_writer:set_chat_folds(self.chat_folds)

    self.widget:set_on_before_hide(function()
        self.chat_folds:capture_visible_fold_states(
            self.message_writer.tool_call_blocks
        )
    end)

    self.widget:set_on_after_show(function(chat_winid)
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            self.chat_folds:on_buf_win_enter(
                chat_winid,
                self.message_writer.tool_call_blocks
            )
        end
    end)

    self:_bind_chat_buffer_events()

    FilePicker:new(self.widget.buf_nrs.input)

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
        function(mode_id, is_legacy)
            self:_handle_mode_change(mode_id, is_legacy)
        end,
        function(model_id, is_legacy)
            self:_handle_model_change(model_id, is_legacy)
        end,
        function(config_id, option_value)
            self:_handle_config_option_change(config_id, option_value)
        end
    )

    self.file_list = FileList:new(self.widget.buf_nrs.files, function(file_list)
        if file_list:is_empty() then
            self.widget:close_optional_window("files")
            self.widget:move_cursor_to(self.widget.win_nrs.input)
        else
            self.widget:render_header("files", tostring(#file_list:get_files()))
            self.widget:show({ focus_prompt = false })
        end
    end)

    self.code_selection = CodeSelection:new(
        self.widget.buf_nrs.code,
        function(code_selection)
            if code_selection:is_empty() then
                self.widget:close_optional_window("code")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                self.widget:render_header(
                    "code",
                    tostring(#code_selection:get_selections())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.diagnostics_list = DiagnosticsList:new(
        self.widget.buf_nrs.diagnostics,
        function(diagnostics_list)
            if diagnostics_list:is_empty() then
                self.widget:close_optional_window("diagnostics")
                self.widget:move_cursor_to(self.widget.win_nrs.input)
            else
                -- show() opens layouts but does not update the diagnostics header count
                self.widget:render_header(
                    "diagnostics",
                    tostring(#diagnostics_list:get_diagnostics())
                )
                self.widget:show({ focus_prompt = false })
            end
        end
    )

    self.todo_list = TodoList:new(self.widget.buf_nrs.todos, function(todo_list)
        if not todo_list:is_empty() then
            self.widget:show({ focus_prompt = false })
        end
    end, function()
        self.widget:close_optional_window("todos")
    end)

    return self
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- order the IF blocks in order of likeliness to be called for performance
    if update.sessionUpdate == "plan" then
        if Config.windows.todos.display then
            --- @diagnostic disable-next-line: param-type-mismatch
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "agent_message_chunk" then
        --- @cast update agentic.acp.AgentMessageChunk
        self.message_writer:write_message_chunk(update)
        self.status_animation:start("generating")

        local chunk_text = update.content and update.content.text
        if chunk_text then
            self.chat_history:append_agent_text({
                type = "agent",
                text = chunk_text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "agent_thought_chunk" then
        --- @cast update agentic.acp.AgentThoughtChunk
        self.message_writer:write_message_chunk(update)
        self.status_animation:start("thinking")

        local chunk_text = update.content and update.content.text
        if chunk_text then
            self.chat_history:append_agent_text({
                type = "thought",
                text = chunk_text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "available_commands_update" then
        --- @diagnostic disable-next-line: param-type-mismatch
        SlashCommands.setCommands(update.availableCommands)
    elseif update.sessionUpdate == "current_mode_update" then
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            --- @diagnostic disable-next-line: param-type-mismatch
            self:_set_mode_to_chat_header(update.currentModeId)
        end
    elseif update.sessionUpdate == "config_option_update" then
        --- @diagnostic disable-next-line: param-type-mismatch
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "usage_update" then
        -- Usage updates contain token/cost information - currently informational only
        -- Fields: used (tokens), size (context window), cost (optional: amount, currency)
        -- Keeping silent for now to avoid "press any key" prompts on large JSON output
    else
        -- TODO: Move this to Logger from notify to debug when confidence is high
        Logger.notify(
            "Unknown session update type: "
                .. tostring(
                    --- @diagnostic disable-next-line: undefined-field -- expected it to be unknown
                    update.sessionUpdate
                ),
            vim.log.levels.WARN,
            { title = "⚠️ Unknown session update" }
        )
    end

    -- Invoke the hook BEFORE render_header so that hook-set state (e.g.
    -- vim.t[].agentic_usage) is available when the header title function runs.
    -- Both are deferred via vim.schedule (FIFO), so this ordering is load-bearing.
    P.invoke_hook("on_session_update", {
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
        update = update,
    })

    self.widget:render_header("chat")
end

--- @param raw string|nil
--- @return agentic.acp.PlanEntryStatus
function P.plan_status_from_cursor(raw)
    if not raw then
        return "pending"
    end

    local r = string.lower(tostring(raw))

    if r == "completed" or r == "done" or r == "complete" then
        return "completed"
    end

    if
        r == "in_progress"
        or r == "inprogress"
        or r == "in progress"
        or r == "active"
    then
        return "in_progress"
    end

    return "pending"
end

--- Normalize Cursor `cursor/update_todos` payloads into ACP plan entries.
--- @param params table
--- @return agentic.acp.PlanEntry[]
function P.cursor_todos_to_plan_entries(params)
    local raw = params.todos or params.entries or params.items

    if type(raw) ~= "table" then
        return {}
    end

    --- @type agentic.acp.PlanEntry[]
    local entries = {}

    for _, item in ipairs(raw) do
        if type(item) == "table" then
            local content = item.content
                or item.text
                or item.title
                or item.label

            if type(content) == "string" and content ~= "" then
                --- @type agentic.acp.PlanEntry
                local entry = {
                    content = content,
                    priority = item.priority or "medium",
                    status = P.plan_status_from_cursor(item.status),
                }
                table.insert(entries, entry)
            end
        elseif type(item) == "string" and item ~= "" then
            --- @type agentic.acp.PlanEntry
            local entry = {
                content = item,
                priority = "medium",
                status = "pending",
            }
            table.insert(entries, entry)
        end
    end

    return entries
end

--- Build a markdown plan summary from `cursor/create_plan` params (shape varies by CLI version).
--- @param params table
--- @return string
function P.cursor_plan_markdown(params)
    local lines = {}

    if type(params.title) == "string" and params.title ~= "" then
        table.insert(lines, "## Plan: " .. params.title)
        table.insert(lines, "")
    end

    if type(params.markdown) == "string" and params.markdown ~= "" then
        table.insert(lines, params.markdown)
    elseif type(params.plan) == "string" and params.plan ~= "" then
        table.insert(lines, params.plan)
    elseif type(params.content) == "string" and params.content ~= "" then
        table.insert(lines, params.content)
    end

    if type(params.steps) == "table" then
        for i, step in ipairs(params.steps) do
            if type(step) == "string" then
                table.insert(lines, string.format("%d. %s", i, step))
            elseif type(step) == "table" then
                local text = step.text
                    or step.content
                    or step.title
                    or step.description

                if type(text) == "string" and text ~= "" then
                    table.insert(lines, string.format("%d. %s", i, text))
                end
            end
        end
    end

    if #lines == 0 then
        return "(No plan details from Cursor.)"
    end

    return table.concat(lines, "\n")
end

--- @param params table
--- @return string|nil path Local file path if available
function P.cursor_image_path(params)
    local path = params.path or params.filePath

    if type(path) == "string" and path ~= "" then
        return path
    end

    local uri = params.uri or params.url

    if type(uri) == "string" and vim.startswith(uri, "file://") then
        return vim.uri_to_fname(uri)
    end

    return nil
end

--- Cursor CLI extension RPCs (`cursor/*`): todos, generated images, interactive Q&A / plan approval.
--- @param ctx agentic.acp.CursorExtensionContext
function SessionManager:_on_cursor_extension(ctx)
    if ctx.method == "cursor/update_todos" then
        local entries = P.cursor_todos_to_plan_entries(ctx.params)

        if Config.windows.todos.display and #entries > 0 then
            self.todo_list:render(entries)
        end

        ctx.respond(vim.empty_dict())
    elseif ctx.method == "cursor/generate_image" then
        local path = P.cursor_image_path(ctx.params)

        --- @type string[]
        local msg = { "🖼 **Generated image**" }

        if path then
            table.insert(msg, "")
            table.insert(
                msg,
                "![img](" .. FileSystem.to_smart_path(path) .. ")"
            )
        else
            table.insert(msg, "")
            table.insert(msg, "(No file path in payload.)")
        end

        self.message_writer:write_message(
            ACPPayloads.generate_agent_message(msg)
        )

        self.chat_history:append_agent_text({
            type = "agent",
            text = table.concat(msg, "\n"),
            provider_name = self.agent.provider_config.name,
        })

        ctx.respond(vim.empty_dict())
    elseif ctx.method == "cursor/ask_question" then
        self:_handle_cursor_ask_question(ctx)
    elseif ctx.method == "cursor/create_plan" then
        self:_handle_cursor_create_plan(ctx)
    else
        ctx.respond(vim.empty_dict())
    end
end

--- @param ctx agentic.acp.CursorExtensionContext
function SessionManager:_handle_cursor_ask_question(ctx)
    local params = ctx.params
    local q = params.question or params.title or params.prompt
    local choices = params.options or params.choices or params.answers

    if type(q) ~= "string" or q == "" then
        ctx.respond(vim.empty_dict())
        return
    end

    if type(choices) ~= "table" or #choices == 0 then
        self.message_writer:write_message(ACPPayloads.generate_agent_message(q))
        ctx.respond(vim.empty_dict())
        return
    end

    --- @type string[]
    local lines = { q, "" }

    for i, ch in ipairs(choices) do
        local label = ""

        if type(ch) == "table" then
            label = ch.label or ch.name or ch.title or ch.text or ""
        elseif type(ch) == "string" then
            label = ch
        end

        table.insert(lines, string.format("- %s) %s", tostring(i), label))
    end

    self.message_writer:write_message(ACPPayloads.generate_agent_message(lines))

    self.status_animation:stop()

    --- @type agentic.acp.PermissionOption[]
    local options = {}

    for i, ch in ipairs(choices) do
        local opt_id = tostring(i)
        local name = ""

        if type(ch) == "table" then
            opt_id = tostring(ch.id or ch.optionId or ch.value or i)
            name = ch.label or ch.name or ch.title or ch.text or opt_id
        elseif type(ch) == "string" then
            name = ch
        end

        --- @type agentic.acp.PermissionOption
        local opt = {
            optionId = opt_id,
            name = name,
            kind = "allow_once",
        }
        table.insert(options, opt)
    end

    local tool_call_id = "cursor_ext_ask_" .. tostring(ctx.message_id or 0)

    --- @type agentic.acp.RequestPermission
    local request = {
        sessionId = self.session_id or "",
        toolCall = {
            toolCallId = tool_call_id,
        },
        options = options,
    }

    local function wrapped_callback(option_id)
        if option_id == nil then
            ctx.respond({
                outcome = {
                    outcome = "cancelled",
                },
            })
        else
            ctx.respond({
                outcome = {
                    outcome = "selected",
                    optionId = option_id,
                },
            })
        end

        self:_clear_diff_in_buffer(request.toolCall.toolCallId, false)

        if
            not self.permission_manager.current_request
            and #self.permission_manager.queue == 0
        then
            self.status_animation:start("generating")
        end
    end

    self:_show_diff_in_buffer(request.toolCall.toolCallId)
    self.permission_manager:add_request(request, wrapped_callback)
end

--- @param ctx agentic.acp.CursorExtensionContext
function SessionManager:_handle_cursor_create_plan(ctx)
    local md = P.cursor_plan_markdown(ctx.params)

    self.message_writer:write_message(ACPPayloads.generate_agent_message(md))

    self.status_animation:stop()

    --- @type agentic.acp.PermissionOption[]
    local options = {}

    local raw_opts = ctx.params.options

    if type(raw_opts) == "table" then
        for _, o in ipairs(raw_opts) do
            if type(o) == "table" then
                local oid = o.optionId or o.id or o.value
                local oname = o.name or o.label or o.title

                if oid and oname then
                    local kind = o.kind or "allow_once"

                    if
                        kind ~= "allow_once"
                        and kind ~= "allow_always"
                        and kind ~= "reject_once"
                        and kind ~= "reject_always"
                    then
                        kind = "allow_once"
                    end
                    --- @cast kind "allow_once"|"allow_always"|"reject_once"|"reject_always"

                    --- @type agentic.acp.PermissionOption
                    local opt = {
                        optionId = tostring(oid),
                        name = tostring(oname),
                        kind = kind,
                    }
                    table.insert(options, opt)
                end
            end
        end
    end

    if #options == 0 then
        --- @type agentic.acp.PermissionOption
        local approve = {
            optionId = "approve",
            name = "Approve plan",
            kind = "allow_once",
        }

        --- @type agentic.acp.PermissionOption
        local reject = {
            optionId = "reject",
            name = "Reject",
            kind = "reject_once",
        }

        table.insert(options, approve)
        table.insert(options, reject)
    end

    local tool_call_id = "cursor_ext_plan_" .. tostring(ctx.message_id or 0)

    --- @type agentic.acp.RequestPermission
    local request = {
        sessionId = self.session_id or "",
        toolCall = {
            toolCallId = tool_call_id,
        },
        options = options,
    }

    local function wrapped_callback(option_id)
        if option_id == nil then
            ctx.respond({
                outcome = {
                    outcome = "cancelled",
                },
            })
        else
            ctx.respond({
                outcome = {
                    outcome = "selected",
                    optionId = option_id,
                },
            })
        end

        self:_clear_diff_in_buffer(request.toolCall.toolCallId, false)

        if
            not self.permission_manager.current_request
            and #self.permission_manager.queue == 0
        then
            self.status_animation:start("generating")
        end
    end

    self:_show_diff_in_buffer(request.toolCall.toolCallId)
    self.permission_manager:add_request(request, wrapped_callback)
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBase
function SessionManager:_on_tool_call_update(tool_call_update)
    self.message_writer:update_tool_call_block(tool_call_update)

    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_call = {
        type = "tool_call",
        tool_call_id = tool_call_update.tool_call_id,
        status = tool_call_update.status,
        body = tool_call_update.body,
        diff = tool_call_update.diff,
        -- Some adapters (e.g. claude-agent-acp) enrich kind/argument on
        -- tool_call_update rather than the initial tool_call. Include them
        -- so chat history reflects the enriched values on session restore.
        kind = tool_call_update.kind,
        argument = tool_call_update.argument,
    }

    self.chat_history:update_tool_call(tool_call_update.tool_call_id, tool_call)

    -- pre-emptively clear diff preview when tool call update is received, as it's either done or failed
    local is_rejection = tool_call_update.status == "failed"
    self:_clear_diff_in_buffer(tool_call_update.tool_call_id, is_rejection)

    -- Remove the permission request if the tool call failed before user granted it
    if tool_call_update.status == "failed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    -- Reload buffers when file-mutating tool calls complete
    if tool_call_update.status == "completed" then
        local tracker =
            self.message_writer.tool_call_blocks[tool_call_update.tool_call_id]

        if tracker and tracker.kind and FILE_MUTATING_KINDS[tracker.kind] then
            vim.cmd.checktime()

            if tracker.argument then
                P.invoke_hook("on_file_edit", {
                    file_path = tracker.argument,
                    session_id = self.session_id,
                    tab_page_id = self.tab_page_id,
                })
            end
        end
    end

    if
        not self.permission_manager.current_request
        and #self.permission_manager.queue == 0
    then
        self.status_animation:start("generating")
    end
end

--- Send the newly selected mode to the agent and handle the response
--- @param mode_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_mode_change(mode_id, is_legacy)
    if not self.session_id then
        return
    end

    local function callback(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change mode to '%s': %s",
                    mode_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            -- needed for backward compatibility
            self.config_options.legacy_agent_modes.current_mode_id = mode_id

            if result and result.configOptions then
                Logger.debug("received result after setting mode")
                self:_handle_new_config_options(result.configOptions)
            end

            self:_set_mode_to_chat_header(mode_id)

            local mode_name = self.config_options:get_mode_name(mode_id)
            Logger.notify(
                "Mode changed to: " .. mode_name,
                vim.log.levels.INFO,
                {
                    title = "Agentic Mode changed",
                }
            )
        end
    end

    if is_legacy then
        self.agent:set_mode(self.session_id, mode_id, callback)
    else
        self.agent:set_config_option(self.session_id, "mode", mode_id, callback)
    end
end

--- Send the newly selected model to the agent
--- @param model_id string
--- @param is_legacy boolean|nil
function SessionManager:_handle_model_change(model_id, is_legacy)
    if not self.session_id then
        return
    end

    local callback = function(result, err)
        if err then
            Logger.notify(
                string.format(
                    "Failed to change model to '%s': %s",
                    model_id,
                    err.message
                ),
                vim.log.levels.ERROR
            )
        else
            local latest_config_options = result and result.configOptions or nil
            if latest_config_options then
                Logger.debug("received result after setting model")
                self:_handle_new_config_options(latest_config_options)
            end

            if is_legacy then
                Logger.notify(
                    "Model changed to: " .. model_id,
                    vim.log.levels.INFO,
                    { title = "Agentic Model changed" }
                )
                return
            end

            local defaults = self.agent.provider_config.default_config_options
            if type(defaults) ~= "table" or vim.tbl_isempty(defaults) then
                Logger.notify(
                    "Model changed to: " .. model_id,
                    vim.log.levels.INFO,
                    { title = "Agentic Model changed" }
                )
                return
            end

            --- @type table<string, string>
            local dependent_defaults = {}
            for config_id, value in pairs(defaults) do
                if config_id ~= "model" and type(value) == "string" then
                    dependent_defaults[config_id] = value
                end
            end

            if vim.tbl_isempty(dependent_defaults) then
                Logger.notify(
                    "Model changed to: " .. model_id,
                    vim.log.levels.INFO,
                    { title = "Agentic Model changed" }
                )
                return
            end

            self:_apply_default_config_options(
                dependent_defaults,
                latest_config_options,
                function(_applied_result, apply_err)
                    if apply_err then
                        Logger.notify(
                            string.format(
                                "Model changed, but failed to apply dependent options: %s",
                                apply_err.message or vim.inspect(apply_err)
                            ),
                            vim.log.levels.WARN,
                            { title = "Agentic Model changed" }
                        )
                        return
                    end

                    Logger.notify(
                        "Model changed to: " .. model_id,
                        vim.log.levels.INFO,
                        { title = "Agentic Model changed" }
                    )
                end
            )
        end
    end

    if is_legacy then
        self.agent:set_model(self.session_id, model_id, callback)
    else
        self.agent:set_config_option(
            self.session_id,
            "model",
            model_id,
            callback
        )
    end
end

--- @param config_id string
--- @param config_value string
function SessionManager:_handle_config_option_change(config_id, config_value)
    if not self.session_id then
        return
    end

    if config_id == "model" then
        self:_handle_model_change(config_value, false)
        return
    end

    self.agent:set_config_option(
        self.session_id,
        config_id,
        config_value,
        function(result, err)
            if err then
                Logger.notify(
                    string.format(
                        "Failed to change %s to '%s': %s",
                        config_id,
                        config_value,
                        err.message
                    ),
                    vim.log.levels.ERROR
                )
                return
            end

            if result and result.configOptions then
                self:_handle_new_config_options(result.configOptions)
            end

            Logger.notify(
                string.format("Updated %s to: %s", config_id, config_value),
                vim.log.levels.INFO,
                { title = "Agentic Config changed" }
            )
        end
    )
end

--- @param config_options agentic.acp.ConfigOption[]|nil
--- @param config_id string
--- @return agentic.acp.ConfigOption|nil
function P.find_config_option(config_options, config_id)
    if type(config_options) ~= "table" then
        return nil
    end

    for _, option in ipairs(config_options) do
        if option.id == config_id then
            return option
        end
    end

    return nil
end

--- @param option agentic.acp.ConfigOption
--- @param value string
--- @return boolean
function P.config_option_supports_value(option, value)
    if not option.options then
        return false
    end

    for _, opt in ipairs(option.options) do
        if opt.value == value then
            return true
        end
    end

    return false
end

--- @param default_config_options table<string, string>
--- @return string[] ordered_ids
function P.build_default_config_order(default_config_options)
    --- @type string[]
    local ordered_ids = {}
    for config_id, _ in pairs(default_config_options) do
        table.insert(ordered_ids, config_id)
    end
    table.sort(ordered_ids)
    return ordered_ids
end

--- @param default_config_options table<string, string>
--- @param config_options agentic.acp.ConfigOption[]|nil
--- @param callback fun(result: table|nil, err: agentic.acp.ACPError|nil)
function SessionManager:_apply_default_config_options(
    default_config_options,
    config_options,
    callback
)
    local ordered_ids = P.build_default_config_order(default_config_options)
    local current_config_options = config_options

    local function apply_next(index)
        local config_id = ordered_ids[index]
        if not config_id then
            callback({ configOptions = current_config_options }, nil)
            return
        end

        local target_value = default_config_options[config_id]
        if target_value == nil or target_value == "" then
            apply_next(index + 1)
            return
        end

        local option = P.find_config_option(current_config_options, config_id)
        if not option then
            apply_next(index + 1)
            return
        end

        if not P.config_option_supports_value(option, target_value) then
            apply_next(index + 1)
            return
        end

        if option.currentValue == target_value then
            apply_next(index + 1)
            return
        end

        self.agent:set_config_option(
            self.session_id,
            config_id,
            target_value,
            function(result, err)
                if err then
                    callback(nil, err)
                    return
                end

                if result and result.configOptions then
                    current_config_options = result.configOptions
                    --- @type agentic.acp.ConfigOption[]
                    local updated_options = result.configOptions
                    self:_handle_new_config_options(updated_options)
                end

                apply_next(index + 1)
            end
        )
    end

    apply_next(1)
end

--- Schedule a coalesced re-render of function-based headers.
--- Multiple calls within the same event loop tick collapse into one render.
function SessionManager:schedule_header_refresh()
    if self._header_refresh_scheduled then
        return
    end
    if not Config.headers then
        return
    end

    self._header_refresh_scheduled = true
    -- Debounce updates within 150ms of each other to avoid excessive
    -- re-renders when multiple updates come in quick succession
    vim.defer_fn(function()
        self._header_refresh_scheduled = false
        for panel_name, header_config in pairs(Config.headers) do
            if type(header_config) == "function" then
                self.widget:render_header(panel_name)
            end
        end
    end, 150)
end

--- @param mode_id string
function SessionManager:_set_mode_to_chat_header(mode_id)
    local mode_name = self.config_options:get_mode_name(mode_id)
    self.widget:render_header(
        "chat",
        string.format("Mode: %s", mode_name or mode_id)
    )
end

--- @param input_text string
function SessionManager:_handle_input_submit(input_text)
    self.todo_list:close_if_all_completed()

    -- Intercept /new command BEFORE the generation guard so users can
    -- escape a stuck state from the chat input
    if input_text:match("^/new%s") or input_text:match("^/new$") then
        self:new_session()
        return
    end

    -- Queue prompt if session is still initializing
    if not self.session_id then
        self._pending_input = input_text
        self.status_animation:start("thinking")
        return
    end

    --- @type agentic.acp.Content[]
    local prompt = {}

    -- If restored/switched session, prepend history on first submit
    if self._history_to_send then
        if not self._replace_session then
            self.chat_history.title = input_text -- Fork: new title from first message
        end
        self._replace_session = false -- Clear flag after use
        ChatHistory.prepend_restored_messages(self._history_to_send, prompt)
        self._history_to_send = nil
    elseif self.chat_history.title == "" then
        self.chat_history.title = input_text -- Set title for new session
    end

    if input_text ~= "" then
        table.insert(prompt, {
            type = "text",
            text = input_text,
        })
    end

    -- Add system info on first message only (after user text so resume picker shows the prompt)
    if self._is_first_message then
        self._is_first_message = false

        table.insert(prompt, {
            type = "text",
            text = self:_get_system_info(),
        })
    end

    --- The message to be written to the chat widget
    local message_lines = {
        string.format("##  User - %s", os.date("%Y-%m-%d %H:%M:%S")),
    }

    table.insert(message_lines, "")
    table.insert(message_lines, input_text)

    if not self.code_selection:is_empty() then
        table.insert(message_lines, "\n- **Selected code**:\n")

        table.insert(prompt, {
            type = "text",
            text = table.concat({
                "IMPORTANT: Focus and respect the line numbers provided in the <line_start> and <line_end> tags for each <selected_code> tag.",
                "The selection shows ONLY the specified line range, not the entire file!",
                "The file may contain duplicated content of the selected snippet.",
                "When using edit tools, on the referenced files, MAKE SURE your changes target the correct lines by including sufficient surrounding context to make the match unique.",
                "After you make edits to the referenced files, go back and read the file to verify your changes were applied correctly.",
            }, "\n"),
        })

        local selections = self.code_selection:get_selections()
        self.code_selection:clear()

        for _, selection in ipairs(selections) do
            if selection and #selection.lines > 0 then
                -- Add line numbers to each line in the snippet
                local numbered_lines = {}
                for i, line in ipairs(selection.lines) do
                    local line_num = selection.start_line + i - 1
                    table.insert(
                        numbered_lines,
                        string.format("Line %d: %s", line_num, line)
                    )
                end
                local numbered_snippet = table.concat(numbered_lines, "\n")

                table.insert(prompt, {
                    type = "text",
                    text = string.format(
                        table.concat({
                            "<selected_code>",
                            "<path>%s</path>",
                            "<line_start>%s</line_start>",
                            "<line_end>%s</line_end>",
                            "<snippet>",
                            "%s",
                            "</snippet>",
                            "</selected_code>",
                        }, "\n"),
                        FileSystem.to_absolute_path(selection.file_path),
                        selection.start_line,
                        selection.end_line,
                        numbered_snippet
                    ),
                })

                table.insert(
                    message_lines,
                    string.format(
                        "```%s %s#L%d-L%d\n%s\n```",
                        selection.file_type,
                        selection.file_path,
                        selection.start_line,
                        selection.end_line,
                        table.concat(selection.lines, "\n")
                    )
                )
            end
        end
    end

    if not self.file_list:is_empty() then
        table.insert(message_lines, "\n- **Referenced files**:")

        local files = self.file_list:get_files()
        self.file_list:clear()

        for _, file_path in ipairs(files) do
            table.insert(prompt, ACPPayloads.create_file_content(file_path))

            table.insert(
                message_lines,
                string.format("  - @%s", FileSystem.to_smart_path(file_path))
            )
        end
    end

    if not self.diagnostics_list:is_empty() then
        table.insert(message_lines, "\n- **Diagnostics**:")

        local diagnostics = self.diagnostics_list:get_diagnostics()
        self.diagnostics_list:clear()

        local WidgetLayout = require("agentic.ui.widget_layout")

        local chat_width = WidgetLayout.calculate_width(Config.windows.width)
        local chat_winid = self.widget.win_nrs.chat
        if chat_winid and vim.api.nvim_win_is_valid(chat_winid) then
            chat_width = vim.api.nvim_win_get_width(chat_winid)
        end

        local DiagnosticsContext = require("agentic.ui.diagnostics_context")

        --- @diagnostic disable-next-line: param-type-mismatch
        local formatted_diagnostics =
            DiagnosticsContext.format_diagnostics(diagnostics, chat_width)

        for _, prompt_entry in ipairs(formatted_diagnostics.prompt_entries) do
            table.insert(prompt, prompt_entry)
        end

        for _, summary_line in ipairs(formatted_diagnostics.summary_lines) do
            table.insert(message_lines, summary_line)
        end
    end

    table.insert(
        message_lines,
        "\n\n### 󱚠 Agent - " .. self.agent.provider_config.name
    )

    local user_message = ACPPayloads.generate_user_message(message_lines)
    self.message_writer:record_prompt_position()
    self.message_writer:write_message(user_message)

    -- Force auto-scroll ON so the response is always visible.
    -- Late session updates (e.g. background process acknowledgements after a
    -- previous turn) can leave _should_auto_scroll in a stale state.
    self.message_writer:enable_auto_scroll()

    --- @type agentic.ui.ChatHistory.UserMessage
    local user_msg = {
        type = "user",
        text = input_text,
        timestamp = os.time(),
        provider_name = self.agent.provider_config.name,
    }
    self.chat_history:add_message(user_msg)

    self.status_animation:start("thinking")

    P.invoke_hook("on_prompt_submit", {
        prompt = input_text,
        session_id = self.session_id,
        tab_page_id = self.tab_page_id,
    })

    local session_id = self.session_id
    local tab_page_id = self.tab_page_id
    -- Capture chat_history before send to avoid race with _cancel_session
    -- replacing self.chat_history while the callback is pending
    local chat_history = self.chat_history

    self.is_generating = true
    self._turn_start_time = vim.uv.hrtime()

    self.agent:send_prompt(self.session_id, prompt, function(response, err)
        vim.schedule(function()
            self.is_generating = false

            local duration_str = P.format_duration(self._turn_start_time)
            self._turn_start_time = nil

            local finish_message = string.format(
                "\n### 🏁 %s (%s)\n-----",
                os.date("%Y-%m-%d %H:%M:%S"),
                duration_str
            )

            if err then
                finish_message = string.format(
                    "\n### %s Agent finished with error: %s\n%s",
                    Config.message_icons.error,
                    vim.inspect(err),
                    finish_message
                )
            elseif response and response.stopReason == "cancelled" then
                finish_message = string.format(
                    "\n### %s Generation stopped by the user request\n%s",
                    Config.message_icons.stopped,
                    finish_message
                )
            end

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message(finish_message)
            )

            self.status_animation:stop()

            P.invoke_hook("on_response_complete", {
                session_id = session_id,
                tab_page_id = tab_page_id,
                success = err == nil,
                error = err,
            })

            -- Save chat history after successful turn completion
            if not err then
                chat_history:save(function(save_err)
                    if save_err then
                        Logger.debug("Chat history save error:", save_err)
                    end
                end)
            end
        end)
    end)
end

--- Create a new session, optionally cancelling any existing one
--- @param opts {restore_mode?: boolean, on_created?: fun()}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode or false
    local on_created = opts.on_created
    if not restore_mode then
        self:_cancel_session()
    end

    self.status_animation:start("busy")

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            Logger.debug("Agent error: ", err)

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message({
                    "🐞 Agent Error:",
                    "",
                    vim.inspect(err),
                })
            )
        end,

        on_session_update = function(update)
            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            self.message_writer:write_tool_call_block(tool_call)
            self.status_animation:start("generating")
            -- Store full tool_call in chat history
            --- @type agentic.ui.ChatHistory.ToolCall
            local tool_msg = {
                type = "tool_call",
                tool_call_id = tool_call.tool_call_id,
                kind = tool_call.kind,
                status = tool_call.status,
                argument = tool_call.argument,
                body = tool_call.body,
                diff = tool_call.diff,
            }
            self.chat_history:add_message(tool_msg)
        end,

        on_tool_call_update = function(tool_call_update)
            self:_on_tool_call_update(tool_call_update)
        end,

        on_request_permission = function(request, callback)
            self.status_animation:stop()

            local function wrapped_callback(option_id)
                callback(option_id)

                local is_rejection = option_id == "reject_once"
                    or option_id == "reject_always"
                self:_clear_diff_in_buffer(
                    request.toolCall.toolCallId,
                    is_rejection
                )

                if
                    not self.permission_manager.current_request
                    and #self.permission_manager.queue == 0
                then
                    self.status_animation:start("generating")
                end
            end

            self:_show_diff_in_buffer(request.toolCall.toolCallId)
            self.permission_manager:add_request(request, wrapped_callback)
        end,

        on_cursor_extension = function(ctx)
            self:_on_cursor_extension(ctx)
        end,
    }

    self.agent:create_session(handlers, function(response, err)
        self.status_animation:stop()

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            return
        end

        self.session_id = response.sessionId
        self.chat_history.session_id = response.sessionId
        self.chat_history.timestamp = os.time()

        if response.configOptions then
            Logger.debug("Provider announce configOptions")
            self:_handle_new_config_options(response.configOptions)
        else
            if response.modes then
                Logger.debug("Provider announce legacy mode")
                self.config_options:set_legacy_modes(response.modes)
                self:_set_mode_to_chat_header(response.modes.currentModeId)
            end

            if response.models then
                Logger.debug("Provider announce legacy models")
                self.config_options:set_legacy_models(response.models)
            end
        end

        self.config_options:set_initial_mode(
            self.agent.provider_config.default_mode,
            function(mode, is_legacy)
                self:_handle_mode_change(mode, is_legacy)
            end
        )

        -- Reset first message flag for new session (skip when restoring)
        if not restore_mode then
            self._is_first_message = true
        end

        -- Add initial welcome message after session is created
        -- Defer to avoid fast event context issues
        -- For restore: write welcome first, then replay via on_created
        vim.schedule(function()
            local welcome_message = SessionManager._generate_welcome_header(
                self.agent.provider_config.name,
                self.session_id
            )

            self.message_writer:write_message(
                ACPPayloads.generate_user_message(welcome_message)
            )

            -- Invoke on_created callback after welcome message is written
            if on_created then
                on_created()
            end

            -- Flush prompt that was queued while session was initializing
            if self._pending_input then
                --- @type string
                local input = self._pending_input
                self._pending_input = nil
                self:_handle_input_submit(input)
            end
        end)
    end)
end

function SessionManager:_bind_chat_buffer_events()
    vim.api.nvim_create_autocmd("BufWinEnter", {
        buffer = self.widget.buf_nrs.chat,
        callback = function()
            local winid = vim.api.nvim_get_current_win()
            self.chat_folds:on_buf_win_enter(
                winid,
                self.message_writer.tool_call_blocks
            )
        end,
    })
end

function SessionManager:_cancel_session()
    self.is_generating = false
    self.status_animation:stop()

    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()

        if self.chat_folds then
            self.chat_folds:reset()
        end
    end

    self.session_id = nil
    self.permission_manager:clear()
    SlashCommands.setCommands({})

    self.chat_history = ChatHistory:new()
    self._history_to_send = nil
end

--- Show the model selector picker and switch to the selected model.
function SessionManager:switch_model()
    self.config_options:show_model_selector(function(model_id, is_legacy)
        self:_handle_model_change(model_id, is_legacy)
    end)
end

--- Show a two-step picker (option name, then option value) and apply selection.
function SessionManager:switch_config_option()
    self.config_options:show_config_option_picker(
        function(config_id, option_value)
            self:_handle_config_option_change(config_id, option_value)
        end
    )
end

--- Switch to a different ACP provider while preserving chat UI and history.
--- Reads Config.provider (already set by caller) for the target provider.
function SessionManager:switch_provider()
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    -- Save references before get_instance (on_ready may fire synchronously)
    local saved_history = self.chat_history
    local old_agent = self.agent
    local old_session_id = self.session_id

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(
        Config.provider,
        function(client)
            vim.schedule(function()
                self.agent = client

                self:new_session({
                    restore_mode = true,
                    on_created = function()
                        local new_history = self.chat_history
                        -- Capture new session metadata before overwriting
                        local new_session_id = new_history.session_id
                        local new_timestamp = new_history.timestamp

                        -- Restore saved messages (new_session created a fresh one)
                        self.chat_history = saved_history
                        self.chat_history.session_id = new_session_id
                        self.chat_history.timestamp = new_timestamp
                        self._history_to_send = saved_history.messages
                        self._is_first_message = true
                    end,
                })
            end)
        end
    )

    if not new_agent then
        return
    end

    -- Soft cancel: tear down old ACP session now that we have a new agent
    if old_session_id then
        old_agent:cancel_session(old_session_id)
    end
    self.session_id = nil
    self.permission_manager:clear()
    self.todo_list:clear()

    -- If agent was already cached, on_ready fired synchronously above.
    -- If not, it will fire when the process is ready.
    self.agent = new_agent
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

function SessionManager:add_selection_to_session()
    local selection = self.code_selection.get_selected_text()

    if selection then
        self.code_selection:add(selection)
        return true
    end

    return false
end

--- @param buf number|string|nil Buffer number or path, if nil the current buffer is used or `0`
function SessionManager:add_file_to_session(buf)
    local bufnr = buf and vim.fn.bufnr(buf) or 0
    local buf_path = vim.api.nvim_buf_get_name(bufnr)

    return self.file_list:add(buf_path)
end

--- Add diagnostics at the current cursor line to context
--- @param bufnr integer|nil Buffer number to get diagnostics from, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_current_line_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_diagnostics_at_cursor(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- Add all diagnostics from the current buffer to context
--- @param bufnr integer|nil Buffer number, defaults to current buffer
--- @return integer count Number of diagnostics added
function SessionManager:add_buffer_diagnostics_to_context(bufnr)
    bufnr = bufnr or vim.api.nvim_get_current_buf()
    local diagnostics = DiagnosticsList.get_buffer_diagnostics(bufnr)
    return self.diagnostics_list:add_many(diagnostics)
end

--- @param tool_call_id string
function SessionManager:_show_diff_in_buffer(tool_call_id)
    -- Only show diff if enabled by user config,
    -- and cursor is in the same tabpage as this session to avoid disruption
    if
        not Config.diff_preview.enabled
        or vim.api.nvim_get_current_tabpage() ~= self.tab_page_id
    then
        return
    end

    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    DiffPreview.show_diff({
        file_path = tracker.argument,
        diff = tracker.diff,
        get_winid = function(bufnr)
            local winid = self.widget:find_first_non_widget_window()
            if not winid then
                return self.widget:open_left_window(bufnr)
            end
            local ok, err = pcall(vim.api.nvim_win_set_buf, winid, bufnr)

            if not ok then
                Logger.notify(
                    "Failed to set buffer in window: " .. tostring(err),
                    vim.log.levels.WARN
                )
                return nil
            end
            return winid
        end,
    })
end

--- @param tool_call_id string
--- @param is_rejection boolean|nil
function SessionManager:_clear_diff_in_buffer(tool_call_id, is_rejection)
    local tracker = tool_call_id
        and self.message_writer.tool_call_blocks[tool_call_id]

    if not tracker or tracker.kind ~= "edit" or tracker.diff == nil then
        return
    end

    DiffPreview.clear_diff(tracker.argument, is_rejection)
end

--- @param new_config_options agentic.acp.ConfigOption[]
function SessionManager:_handle_new_config_options(new_config_options)
    self.config_options:set_options(new_config_options)

    if self.config_options.mode and self.config_options.mode.currentValue then
        self:_set_mode_to_chat_header(self.config_options.mode.currentValue)
    end
end

function SessionManager:_get_system_info()
    local _ = self
    local os_name = vim.uv.os_uname().sysname
    local os_version = vim.uv.os_uname().release
    local os_machine = vim.uv.os_uname().machine
    local shell = os.getenv("SHELL")
    local neovim_version = tostring(vim.version())
    local today = os.date("%Y-%m-%d")

    local res = string.format(
        [[
- Platform: %s-%s-%s
- Shell: %s
- Editor: Neovim %s
- Current date: %s]],
        os_name,
        os_version,
        os_machine,
        shell,
        neovim_version,
        today
    )

    local project_root = vim.uv.cwd()

    local git_root = vim.fs.root(project_root or 0, ".git")
    if git_root then
        project_root = git_root
        res = res .. "\n- This is a Git repository."

        local branch =
            vim.fn.system("git rev-parse --abbrev-ref HEAD"):gsub("\n", "")
        if vim.v.shell_error == 0 and branch ~= "" then
            res = res .. string.format("\n- Current branch: %s", branch)
        end

        local changed = vim.fn.system("git status --porcelain"):gsub("\n$", "")
        if vim.v.shell_error == 0 and changed ~= "" then
            local files = vim.split(changed, "\n")
            res = res .. "\n- Changed files:"
            for _, file in ipairs(files) do
                res = res .. "\n  - " .. file
            end
        end

        local commits = vim.fn
            .system("git log -3 --oneline --format='%h (%ar) %an: %s'")
            :gsub("\n$", "")
        if vim.v.shell_error == 0 and commits ~= "" then
            local commit_lines = vim.split(commits, "\n")
            res = res .. "\n- Recent commits:"
            for _, commit in ipairs(commit_lines) do
                res = res .. "\n  - " .. commit
            end
        end
    end

    if project_root then
        res = res .. string.format("\n- Project root: %s", project_root)
    end

    res = "<environment_info>\n" .. res .. "\n</environment_info>"
    return res
end

function SessionManager:destroy()
    self:_cancel_session()
    self.widget:destroy()
end

--- Restore session from loaded chat history.
--- Always creates a new ACP session (provider doesn't persist sessions)
--- and replays messages to UI. History is prepended on first prompt submit.
--- @param history agentic.ui.ChatHistory
--- @param opts {replace_session?: boolean}|nil If replace_session=true, keep original session identity for file persistence (continue mode)
function SessionManager:restore_from_history(history, opts)
    opts = opts or {}

    -- Prevent constructor's auto-new_session from running
    self._restoring = true
    self._history_to_send = history.messages
    self._is_first_message = false
    self.chat_history = history

    -- In continue mode, remember original identity to restore after new_session
    local original_session_id = opts.replace_session and history.session_id
        or nil
    local original_timestamp = opts.replace_session and history.timestamp or nil

    -- Always reset this flag per restore operation so previous mode
    -- does not leak into the next restore.
    self._replace_session = opts.replace_session == true

    local SessionRestore = require("agentic.session_restore")

    self:new_session({
        restore_mode = true,
        on_created = function()
            -- In continue mode, restore original session identity
            -- so saves overwrite the same file instead of creating a new one
            if original_session_id then
                self.chat_history.session_id = original_session_id
            end
            if original_timestamp then
                self.chat_history.timestamp = original_timestamp
            end

            self._restoring = false
            SessionRestore.replay_messages(
                self.message_writer,
                self._history_to_send
            )
        end,
    })
end

return SessionManager
