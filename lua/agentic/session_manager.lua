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

--- @type table<string, boolean|nil>
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

--- Data fields initialized in the constructor. Kept separate from the full class
--- so LuaLS does not require prototype methods on the constructor table literal.
--- @class agentic.SessionManagerData
--- @field session_id? string
--- @field tab_page_id integer
--- @field provider_name agentic.UserConfig.ProviderName
--- @field _is_first_message boolean
--- @field is_generating boolean
--- @field _turn_start_time? number
--- @field _pending_input? string
--- @field widget? agentic.ui.ChatWidget
--- @field agent? agentic.acp.ACPClient
--- @field message_writer? agentic.ui.MessageWriter
--- @field permission_manager? agentic.ui.PermissionManager
--- @field status_animation? agentic.ui.StatusAnimation
--- @field file_list? agentic.ui.FileList
--- @field code_selection? agentic.ui.CodeSelection
--- @field diagnostics_list? agentic.ui.DiagnosticsList
--- @field config_options? agentic.acp.AgentConfigOptions
--- @field todo_list? agentic.ui.TodoList
--- @field chat_history? agentic.ui.ChatHistory
--- @field chat_folds? agentic.ui.ChatFolds
--- @field _header_refresh_scheduled boolean
--- @field _history_to_send? agentic.ui.ChatHistory.Message[]
--- @field _history_replay_source? agentic.ui.ChatHistory.ReplaySource
--- @field _restoring boolean
--- @field _replace_session boolean
--- @field _is_creating_session boolean
--- @field _is_switching_provider boolean
--- @field _provider_switch_id integer
--- @field _session_create_id integer
--- @field _turn_generation integer
--- @field _pending_agent_message_text? string
--- @field _pending_agent_message_provider_name? string
--- @field _pending_agent_message_generation? integer
--- @field _agent_message_generation integer

--- @class agentic.SessionManager : agentic.SessionManagerData
--- @field session_id? string
--- @field tab_page_id integer
--- @field provider_name agentic.UserConfig.ProviderName
--- @field _is_first_message boolean Whether the first user turn is still pending; also marks sessions eligible for prewarming
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
--- @field _header_refresh_scheduled boolean
--- @field _history_to_send? agentic.ui.ChatHistory.Message[] Messages to prepend on next prompt submit
--- @field _history_replay_source? agentic.ui.ChatHistory.ReplaySource Messages to prepend on next prompt submit
--- @field _restoring boolean Flag to prevent auto-new_session during restore
--- @field _replace_session boolean When true, preserve loaded session identity on next submit (continue mode)
--- @field _is_creating_session boolean True once session startup is requested, until session/new resolves
--- @field _is_switching_provider boolean True while a provider switch is waiting for the replacement session
--- @field _provider_switch_id integer Monotonic token used to ignore stale provider switch callbacks
--- @field _session_create_id integer Monotonic token used to ignore stale session creation callbacks
--- @field _turn_generation integer Monotonic token used to ignore stale prompt completions
--- @field _pending_agent_message_text? string Text buffered across adjacent agent message chunks
--- @field _pending_agent_message_provider_name? string Provider name for buffered message history
--- @field _pending_agent_message_generation? integer Generation captured by the scheduled flush
--- @field _agent_message_generation integer Invalidates flushes from replaced turns/sessions
local SessionManager = {}
SessionManager.__index = SessionManager

local function start_animation_if_owned(session, mode)
    if session.is_generating or session._is_creating_session then
        session.status_animation:start(mode)
    end
end

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
--- @param provider_name agentic.UserConfig.ProviderName
--- @return agentic.SessionManager|nil
function SessionManager:new(tab_page_id, provider_name)
    local AgentInstance = require("agentic.acp.agent_instance")
    local ChatWidget = require("agentic.ui.chat_widget")
    local CodeSelection = require("agentic.ui.code_selection")
    local FileList = require("agentic.ui.file_list")
    local MessageWriter = require("agentic.ui.message_writer")
    local PermissionManager = require("agentic.ui.permission_manager")
    local StatusAnimation = require("agentic.ui.status_animation")
    local TodoList = require("agentic.ui.todo_list")
    local AgentConfigOptions = require("agentic.acp.agent_config_options")

    --- @type agentic.SessionManagerData
    local instance = {
        session_id = nil,
        tab_page_id = tab_page_id,
        provider_name = provider_name,
        _is_first_message = true,
        is_generating = false,
        _header_refresh_scheduled = false,
        _restoring = false,
        _replace_session = false,
        _is_creating_session = false,
        _is_switching_provider = false,
        _provider_switch_id = 0,
        _session_create_id = 0,
        _turn_generation = 0,
        _pending_agent_message_text = nil,
        _pending_agent_message_provider_name = nil,
        _pending_agent_message_generation = nil,
        _agent_message_generation = 0,
    }
    self = setmetatable(instance, self)

    local agent = AgentInstance.get_instance(provider_name, function(_client)
        vim.schedule(function()
            -- Skip auto-new_session if restore_from_history was called
            if not self._restoring then
                self:new_session({
                    skip_reuse_check = true,
                })
            end
        end)
    end)

    if not agent then
        -- no log, it was already logged in AgentInstance
        return
    end

    self.agent = agent
    self._is_creating_session = true

    self.chat_history =
        ChatHistory:new(ChatHistory.get_sessions_folder(tab_page_id))

    self.widget = ChatWidget:new(tab_page_id, function(input_text)
        self:_handle_input_submit(input_text)
    end)

    self.message_writer = MessageWriter:new(self.widget.buf_nrs.chat)
    self.widget.message_writer = self.message_writer
    self.status_animation = StatusAnimation:new(self.widget.buf_nrs.chat)
    self.permission_manager = PermissionManager:new(
        self.message_writer,
        function()
            return self.agent and self.agent.provider_config or nil
        end
    )

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

    self.config_options = AgentConfigOptions:new(
        self.widget.buf_nrs,
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

--- @return agentic.UserConfig.ProviderName
function SessionManager:get_provider_name()
    if self.provider_name ~= nil then
        return self.provider_name
    end

    for candidate_provider_name, provider_config in pairs(Config.acp_providers) do
        if
            self.agent ~= nil
            and self.agent.provider_config == provider_config
        then
            self.provider_name = candidate_provider_name
            return candidate_provider_name
        end
    end

    return Config.provider
end

--- Schedule a flush so a pure stream remains visible without delaying it.
function SessionManager:_schedule_pending_agent_message_flush()
    if self._pending_agent_message_generation ~= nil then
        return
    end

    local generation = self._agent_message_generation or 0
    self._pending_agent_message_generation = generation
    local instance = self
    vim.schedule(function()
        -- The callback may run after a synchronous flush and a new stream.
        -- Only the instance and pending generation that scheduled it may flush.
        if instance._pending_agent_message_generation == generation then
            instance:_flush_pending_agent_message(generation)
        end
    end)
end

--- Flush buffered agent text before another update can change its ordering.
--- @param generation integer|nil Only flush this scheduled generation when set.
function SessionManager:_flush_pending_agent_message(generation)
    if
        generation ~= nil
        and generation ~= self._pending_agent_message_generation
    then
        return
    end

    -- A synchronous flush invalidates the scheduled callback. This also
    -- prevents an old callback from flushing text from a later turn.
    if generation == nil then
        self._agent_message_generation = (self._agent_message_generation or 0)
            + 1
    end

    local text = self._pending_agent_message_text
    --- @type string|nil
    local provider_name = self._pending_agent_message_provider_name
    self._pending_agent_message_text = nil
    self._pending_agent_message_provider_name = nil
    self._pending_agent_message_generation = nil
    if not text then
        return
    end

    -- The provider name is captured when buffering starts, so flushing does
    -- not depend on the agent still being attached to this session.
    provider_name = provider_name or self.provider_name or Config.provider
    if type(provider_name) ~= "string" then
        return
    end

    -- MessageWriter intentionally does not return rendered text. The buffered
    -- text is already the canonical history representation for this update.
    self.message_writer:write_message_chunk(
        ACPPayloads.generate_agent_message(text)
    )
    self.chat_history:append_agent_text({
        type = "agent",
        text = text,
        provider_name = provider_name,
    })
end

--- Flush current text and invalidate callbacks from the old turn/session.
function SessionManager:_invalidate_pending_agent_message()
    self:_flush_pending_agent_message()
end

-- Lightweight session fixtures may intentionally omit the SessionManager
-- metatable. Real sessions resolve these methods through that metatable, while
-- the guards keep lifecycle callbacks safe for partial session objects.
local function flush_pending_agent_message(session)
    local flush = session._flush_pending_agent_message
    if flush then
        flush(session)
    end
end

local function invalidate_pending_agent_message(session)
    local invalidate = session._invalidate_pending_agent_message
    if invalidate then
        invalidate(session)
    else
        flush_pending_agent_message(session)
    end
end

--- @param update agentic.acp.SessionUpdateMessage
function SessionManager:_on_session_update(update)
    -- A buffered message must be written before any other update is handled.
    if update.sessionUpdate ~= "agent_message_chunk" then
        flush_pending_agent_message(self)
    end

    -- order the IF blocks in order of likeliness to be called for performance
    if update.sessionUpdate == "plan" then
        --- @cast update agentic.acp.PlanUpdate
        if Config.windows.todos.display then
            self.todo_list:render(update.entries)
        end
    elseif update.sessionUpdate == "agent_message_chunk" then
        --- @cast update agentic.acp.AgentMessageChunk
        local chunk_text = update.content and update.content.text
        if update.content and update.content.type == "text" and chunk_text then
            if chunk_text ~= "" then
                self._pending_agent_message_text = (
                    self._pending_agent_message_text or ""
                ) .. chunk_text
                self._pending_agent_message_provider_name = self._pending_agent_message_provider_name
                    or self.agent.provider_config.name
                self:_schedule_pending_agent_message_flush()
            end
        else
            flush_pending_agent_message(self)
            self.message_writer:write_message_chunk(update)
            local content_text = update.content and update.content.text
            if content_text then
                self.chat_history:append_agent_text({
                    type = "agent",
                    text = content_text,
                    provider_name = self.agent.provider_config.name,
                })
            end
        end
        start_animation_if_owned(self, "generating")
    elseif update.sessionUpdate == "agent_thought_chunk" then
        --- @cast update agentic.acp.AgentThoughtChunk
        self.message_writer:write_message_chunk(update)
        start_animation_if_owned(self, "thinking")

        local content_text = update.content and update.content.text
        if content_text then
            self.chat_history:append_agent_text({
                type = "thought",
                text = content_text,
                provider_name = self.agent.provider_config.name,
            })
        end
    elseif update.sessionUpdate == "available_commands_update" then
        --- @cast update agentic.acp.AvailableCommandsUpdate
        SlashCommands.setCommands(
            self.widget.buf_nrs.input,
            update.availableCommands
        )
    elseif update.sessionUpdate == "current_mode_update" then
        --- @cast update agentic.acp.CurrentModeUpdate
        -- only for legacy modes, not for config_options
        if
            self.config_options.legacy_agent_modes:handle_agent_update_mode(
                update.currentModeId
            )
        then
            self:_set_mode_to_chat_header(update.currentModeId)
        end
    elseif update.sessionUpdate == "config_option_update" then
        --- @cast update agentic.acp.ConfigOptionsUpdate
        self:_handle_new_config_options(update.configOptions)
    elseif update.sessionUpdate == "session_info_update" then
        -- Cursor may emit session metadata updates (e.g. title); ignore for now.
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
    local questions = params.questions

    if type(questions) ~= "table" or #questions == 0 then
        ctx.respond({ outcome = { outcome = "cancelled" } })
        return
    end

    for _, question in ipairs(questions) do
        if
            type(question) ~= "table"
            or type(question.prompt) ~= "string"
            or question.prompt == ""
            or type(question.options) ~= "table"
            or #question.options == 0
            or question.allowMultiple == true
        then
            ctx.respond({ outcome = { outcome = "cancelled" } })
            return
        end
    end

    self.status_animation:stop()

    local answers = {}
    local question_index = 1

    local function finish(request, outcome)
        ctx.respond({ outcome = outcome })
        self:_clear_diff_in_buffer(request.toolCall.toolCallId, false)

        if
            not self.permission_manager.current_request
            and #self.permission_manager.queue == 0
        then
            start_animation_if_owned(self, "generating")
        end
    end

    local function queue_question()
        local question = questions[question_index]
        local question_id = tostring(question.id or question_index)
        --- @type string[]
        local lines = { question.prompt, "" }
        --- @type agentic.acp.PermissionOption[]
        local options = {}

        for i, choice in ipairs(question.options) do
            local option_id = tostring(i)
            local name = ""
            if type(choice) == "table" then
                option_id =
                    tostring(choice.id or choice.optionId or choice.value or i)
                name = choice.label
                    or choice.name
                    or choice.title
                    or choice.text
                    or option_id
            elseif type(choice) == "string" then
                name = choice
            end
            table.insert(lines, string.format("- %s) %s", tostring(i), name))
            table.insert(options, {
                optionId = option_id,
                name = name,
                kind = "allow_once",
            })
        end

        self.message_writer:write_message(
            ACPPayloads.generate_agent_message(lines)
        )

        local request = {
            sessionId = self.session_id or "",
            toolCall = {
                toolCallId = "cursor_ext_ask_"
                    .. tostring(ctx.message_id or 0)
                    .. "_"
                    .. tostring(question_index),
            },
            options = options,
        }

        local function callback(option_id)
            if option_id == nil then
                finish(request, { outcome = "cancelled" })
                return
            end

            table.insert(answers, {
                questionId = question_id,
                selectedOptionIds = { option_id },
            })
            self:_clear_diff_in_buffer(request.toolCall.toolCallId, false)
            question_index = question_index + 1
            if question_index <= #questions then
                queue_question()
            else
                finish(request, {
                    outcome = "answered",
                    answers = answers,
                })
            end
        end

        self:_show_diff_in_buffer(request.toolCall.toolCallId)
        self.permission_manager:add_request(request, callback)
    end

    queue_question()
end

--- @param ctx agentic.acp.CursorExtensionContext
function SessionManager:_handle_cursor_create_plan(ctx)
    local md = P.cursor_plan_markdown(ctx.params)

    self.message_writer:write_message(ACPPayloads.generate_agent_message(md))

    self.status_animation:stop()

    --- @type agentic.acp.PermissionOption[]
    local options = {}
    --- @type table<string, "accepted"|"rejected">
    local option_outcomes = {}

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
                    option_outcomes[opt.optionId] = (
                        kind == "reject_once" or kind == "reject_always"
                    )
                            and "rejected"
                        or "accepted"
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
        option_outcomes[approve.optionId] = "accepted"
        option_outcomes[reject.optionId] = "rejected"
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
                    outcome = option_outcomes[option_id] or "accepted",
                },
            })
        end

        self:_clear_diff_in_buffer(request.toolCall.toolCallId, false)

        if
            not self.permission_manager.current_request
            and #self.permission_manager.queue == 0
        then
            start_animation_if_owned(self, "generating")
        end
    end

    self:_show_diff_in_buffer(request.toolCall.toolCallId)
    self.permission_manager:add_request(
        request,
        wrapped_callback,
        { disable_auto_approve = true }
    )
end

--- Handle tool call update: update UI, history, diff preview, permissions, and reload buffers
--- @param tool_call_update agentic.ui.MessageWriter.ToolCallBase
function SessionManager:_on_tool_call_update(tool_call_update)
    local is_terminal = tool_call_update.status == "completed"
        or tool_call_update.status == "failed"
        or tool_call_update.status == "cancelled"
    local is_rejection = tool_call_update.status == "failed"

    if is_terminal then
        self:_clear_diff_in_buffer(tool_call_update.tool_call_id, is_rejection)
    end

    -- A rendered diff is intentionally immutable. Capture whether this tool
    -- call already had the displayed diff before the writer updates tracker
    -- metadata, so history never records a later diff that was not shown.
    local tracker_before_update = rawget(
        self.message_writer.tool_call_blocks,
        tool_call_update.tool_call_id
    )
    local had_rendered_diff = tracker_before_update
        and tracker_before_update._rendered_diff == true

    self.message_writer:update_tool_call_block(tool_call_update)

    --- @type agentic.ui.ChatHistory.ToolCall
    local tool_call = {
        type = "tool_call",
        tool_call_id = tool_call_update.tool_call_id,
        status = tool_call_update.status,
        body = tool_call_update.body,
        -- Some adapters (e.g. claude-agent-acp) enrich kind/argument on
        -- tool_call_update rather than the initial tool_call. Include them
        -- so chat history reflects the enriched values on session restore.
        kind = tool_call_update.kind,
        argument = tool_call_update.argument,
    }
    if not had_rendered_diff then
        tool_call.diff = tool_call_update.diff
    end

    self.chat_history:update_tool_call(tool_call_update.tool_call_id, tool_call)

    -- pre-emptively clear diff preview when tool call update is received, as it's either done or failed
    if not is_terminal then
        self:_clear_diff_in_buffer(tool_call_update.tool_call_id, is_rejection)
    end

    -- Remove the permission request if the tool call ended before user granted it
    if is_terminal and tool_call_update.status ~= "completed" then
        self.permission_manager:remove_request_by_tool_call_id(
            tool_call_update.tool_call_id
        )
    end

    -- Reload buffers when file-mutating tool calls complete
    if tool_call_update.status == "completed" then
        local tracker = rawget(
            self.message_writer.tool_call_blocks,
            tool_call_update.tool_call_id
        )

        if tracker and FILE_MUTATING_KINDS[tracker.kind] then
            vim.cmd.checktime()

            P.invoke_hook("on_file_edit", {
                file_path = tracker.argument,
                session_id = self.session_id,
                tab_page_id = self.tab_page_id,
            })
        end
    end

    if
        not self.permission_manager.current_request
        and #self.permission_manager.queue == 0
    then
        start_animation_if_owned(self, "generating")
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

            -- nil preserves the legacy fallback; an empty table intentionally
            -- disables reapplication after an interactive model change.
            local model_change_config_options =
                self.agent.provider_config.model_change_config_options
            local defaults = model_change_config_options
                or self.agent.provider_config.default_config_options
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
                if
                    (model_change_config_options ~= nil or config_id ~= "model")
                    and type(value) == "string"
                then
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

            local latest_config_options = result and result.configOptions or nil
            if latest_config_options then
                self:_handle_new_config_options(latest_config_options)
            end

            if config_id == "provider" and latest_config_options then
                local model_change_config_options =
                    self.agent.provider_config.model_change_config_options
                local defaults = model_change_config_options
                    or self.agent.provider_config.default_config_options
                --- @type table<string, string>
                local dependent_defaults = {}

                if type(defaults) == "table" then
                    for dependent_id, value in pairs(defaults) do
                        if
                            dependent_id ~= "provider"
                            and dependent_id ~= "model"
                            and type(value) == "string"
                        then
                            dependent_defaults[dependent_id] = value
                        end
                    end
                end

                if not vim.tbl_isempty(dependent_defaults) then
                    self:_apply_default_config_options(
                        dependent_defaults,
                        latest_config_options,
                        function(_applied_result, apply_err)
                            if apply_err then
                                Logger.notify(
                                    string.format(
                                        "Provider changed, but failed to apply dependent options: %s",
                                        apply_err.message
                                            or vim.inspect(apply_err)
                                    ),
                                    vim.log.levels.WARN,
                                    { title = "Agentic Config changed" }
                                )
                            end
                        end
                    )
                end
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

        local session_id = self.session_id
        if not session_id then
            --- @type agentic.acp.ACPError
            local error = {
                code = self.agent.ERROR_CODES.SESSION_NOT_FOUND,
                message = "Cannot set config option before session is initialized",
            }
            callback(nil, error)
            return
        end

        self.agent:set_config_option(
            session_id,
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
    local history_source = self._history_replay_source or self._history_to_send
    if history_source then
        local replay_ok, replay_err =
            ChatHistory.prepend_restored_messages(history_source, prompt)
        if not replay_ok then
            Logger.notify(
                "Failed to restore chat history: "
                    .. (replay_err or "unknown error"),
                vim.log.levels.ERROR
            )
            return
        end
        if not self._replace_session then
            self.chat_history.title = input_text -- Fork: new title from first message
        end
        self._replace_session = false -- Clear flag after use
        self._history_replay_source = nil
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

    -- Mark the first message as handled after recording the user text
    if self._is_first_message then
        self._is_first_message = false
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
                        "````%s %s#L%d-L%d\n%s\n````",
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
        --- @cast chat_width integer

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
    self._turn_generation = (self._turn_generation or 0) + 1
    local turn_generation = self._turn_generation
    -- Capture chat_history before send to avoid race with _cancel_session
    -- replacing self.chat_history while the callback is pending
    local chat_history = self.chat_history

    self.is_generating = true
    self._turn_start_time = vim.uv.hrtime()

    self.agent:send_prompt(session_id, prompt, function(response, err)
        vim.schedule(function()
            if self._turn_generation ~= turn_generation then
                return
            end

            flush_pending_agent_message(self)
            self.is_generating = false

            local duration_str = P.format_duration(self._turn_start_time)
            self._turn_start_time = nil

            local completed_at = os.time()
            local finish_message =
                ChatHistory.format_turn_end(completed_at, duration_str)

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

            --- @type agentic.ui.ChatHistory.TurnEndMessage
            local turn_end = {
                type = "turn_end",
                timestamp = completed_at,
                duration = duration_str,
            }
            chat_history:add_message(turn_end)

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
--- @param opts {restore_mode?: boolean, on_created?: fun(), skip_reuse_check?: boolean}|nil
function SessionManager:new_session(opts)
    opts = opts or {}
    local restore_mode = opts.restore_mode == true
    local on_created = opts.on_created
    local provider_name = SessionManager.get_provider_name(self)
    if not restore_mode and opts.skip_reuse_check ~= true then
        if SessionManager.get_new_session_reuse_reason(self, provider_name) then
            return
        end
    end
    if not restore_mode then
        self:_cancel_session()
    else
        self._turn_generation = (self._turn_generation or 0) + 1
    end

    self.status_animation:start("busy")
    self._is_creating_session = true
    self._session_create_id = (self._session_create_id or 0) + 1
    local session_create_id = self._session_create_id

    local is_current_session = function()
        return self._session_create_id == session_create_id
    end

    --- @type agentic.acp.ClientHandlers
    local handlers = {
        on_error = function(err)
            if not is_current_session() then
                return
            end

            Logger.debug("Agent error: ", err)
            flush_pending_agent_message(self)

            self.message_writer:write_message(
                ACPPayloads.generate_agent_message({
                    "🐞 Agent Error:",
                    "",
                    vim.inspect(err),
                })
            )
        end,

        on_session_update = function(update)
            if not is_current_session() then
                return
            end

            self:_on_session_update(update)
        end,

        on_tool_call = function(tool_call)
            if not is_current_session() then
                return
            end

            flush_pending_agent_message(self)

            --- @type agentic.ui.ChatHistory.ToolCall
            local tool_msg = {
                type = "tool_call",
                tool_call_id = tool_call.tool_call_id,
                kind = tool_call.kind,
                status = tool_call.status,
                argument = tool_call.argument,
                body = tool_call.body and vim.deepcopy(tool_call.body) or nil,
                diff = tool_call.diff and vim.deepcopy(tool_call.diff) or nil,
            }

            self.message_writer:write_tool_call_block(tool_call)
            start_animation_if_owned(self, "generating")
            self.chat_history:add_message(tool_msg)
        end,

        on_tool_call_update = function(tool_call_update)
            if not is_current_session() then
                return
            end

            flush_pending_agent_message(self)
            self:_on_tool_call_update(tool_call_update)
        end,

        on_request_permission = function(request, callback)
            if not is_current_session() then
                callback(nil)
                return
            end

            self.status_animation:stop()

            local callback_called = false
            local function wrapped_callback(option_id)
                if callback_called then
                    return
                end
                if not is_current_session() and option_id ~= nil then
                    return
                end

                callback_called = true
                callback(option_id)

                if not is_current_session() then
                    return
                end

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
                    start_animation_if_owned(self, "generating")
                end
            end

            self:_show_diff_in_buffer(request.toolCall.toolCallId)
            self.permission_manager:add_request(request, wrapped_callback)
        end,

        on_cursor_extension = function(ctx)
            if not is_current_session() then
                return
            end

            self:_on_cursor_extension(ctx)
        end,
    }

    -- Captured so a stale callback cancels the orphan on the agent that
    -- actually created it, even after `switch_provider` swapped `self.agent`.
    local creating_agent = self.agent

    self.agent:create_session(handlers, function(response, err)
        local current_session_create_id = self._session_create_id
        if current_session_create_id ~= session_create_id then
            -- Stale create: another new_session/cancel/provider-switch already
            -- superseded this request. Salvage what belongs to the agent
            -- instance rather than the session before dropping the response.
            if response then
                -- Capabilities describe the agent process, not the session. On
                -- a restore-first flow this response is their only source, so
                -- discarding it breaks mode/model switching for the whole tab.
                -- Only adopt them while that process is still the active one:
                -- `switch_provider` also supersedes creates, and adopting there
                -- would overwrite the live provider's modes (and the chat
                -- header) with a dead provider's.
                --
                -- DO NOT collapse the two sides of this comparison. They are
                -- deliberately different expressions: `creating_agent` is the
                -- agent captured when this create was issued, `self.agent` is
                -- whatever is active by the time the response lands. Comparing
                -- them IS the check. emmylua sees the second read of
                -- `self.agent` and suggests reusing the local, which would
                -- yield `creating_agent == creating_agent` — always true,
                -- silently restoring the provider-switch clobbering bug that
                -- only `new_session`'s two "superseded provider" tests catch.
                --- @diagnostic disable-next-line: preferred-local-alias
                if creating_agent == self.agent then
                    if response.configOptions then
                        Logger.debug("Stale create announced configOptions")
                        self:_handle_new_config_options(response.configOptions)
                    else
                        if response.modes then
                            Logger.debug("Stale create announced legacy modes")
                            self.config_options:set_legacy_modes(response.modes)
                            self:_set_mode_to_chat_header(
                                response.modes.currentModeId
                            )
                        end

                        if response.models then
                            Logger.debug("Stale create announced legacy models")
                            self.config_options:set_legacy_models(
                                response.models
                            )
                        end
                    end
                end

                -- The session itself is orphaned regardless of which agent is
                -- active now, so always tear it down on its own agent.
                creating_agent:cancel_session(response.sessionId)
            end

            return
        end

        self.status_animation:stop()
        self._is_creating_session = false

        if err or not response then
            -- no log here, already logged in create_session
            self.session_id = nil
            self._is_switching_provider = false
            return
        end

        self.session_id = response.sessionId
        self.chat_history.session_id = response.sessionId
        self.chat_history.acp_session_id = response.sessionId
        local now = os.time()
        self.chat_history.created_at = now
        self.chat_history.updated_at = now

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
            if not is_current_session() then
                return
            end

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

            if not is_current_session() then
                return
            end

            self.chat_history:save(function(save_err)
                if save_err then
                    Logger.debug("Chat history save error:", save_err)
                end
            end)

            if not is_current_session() then
                return
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
    invalidate_pending_agent_message(self)
    self.is_generating = false
    self._turn_generation = (self._turn_generation or 0) + 1
    self.status_animation:stop()
    self._is_creating_session = false
    self._session_create_id = (self._session_create_id or 0) + 1

    if self.session_id then
        -- only cancel and clear content if there was an session
        -- Otherwise, it clears selections and files when opening for the first time
        self.agent:cancel_session(self.session_id)
        self.widget:clear()
        self.message_writer:clear_navigation_positions()
        self.message_writer.tool_call_blocks = {}
        self.todo_list:clear()
        self.file_list:clear()
        self.code_selection:clear()
        self.diagnostics_list:clear()
        self.config_options:clear()

        self.chat_folds:reset()
    end

    self.session_id = nil
    self.permission_manager:clear()
    SlashCommands.setCommands(self.widget.buf_nrs.input, {})

    self.chat_history =
        ChatHistory:new(ChatHistory.get_sessions_folder(self.tab_page_id))
    self._history_to_send = nil
    self._history_replay_source = nil
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
--- @param provider_name agentic.UserConfig.ProviderName
function SessionManager:switch_provider(provider_name)
    if self.is_generating then
        Logger.notify(
            "Cannot switch provider while generating. Stop generation first.",
            vim.log.levels.WARN
        )
        return
    end

    if SessionManager.uses_provider(self, provider_name) then
        return
    end

    local AgentInstance = require("agentic.acp.agent_instance")

    -- Save references before get_instance (on_ready may fire synchronously)
    local saved_history = self.chat_history
    local saved_replay_source = type(saved_history.get_replay_source)
                == "function"
            and saved_history:get_replay_source()
        or { kind = "messages", messages = saved_history.messages or {} }
    local saved_messages, replay_err =
        ChatHistory.collect_messages(saved_replay_source)
    if not saved_messages then
        Logger.notify(
            "Failed to switch provider: "
                .. (replay_err or "unable to load chat history"),
            vim.log.levels.ERROR
        )
        return
    end
    saved_replay_source = { kind = "messages", messages = saved_messages }
    local old_agent = self.agent
    local old_session_id = self.session_id
    self._provider_switch_id = (self._provider_switch_id or 0) + 1
    local provider_switch_id = self._provider_switch_id
    self._is_switching_provider = true
    self._session_create_id = (self._session_create_id or 0) + 1

    -- Get new agent instance BEFORE tearing down the current session
    local new_agent = AgentInstance.get_instance(provider_name, function(client)
        vim.schedule(function()
            local current_provider_switch_id = self._provider_switch_id
            if current_provider_switch_id ~= provider_switch_id then
                return
            end

            self.agent = client
            self.provider_name = provider_name

            self:new_session({
                restore_mode = true,
                on_created = function()
                    local new_history = self.chat_history
                    new_history.title = saved_history.title
                    local copy_ok, copy_err, copied_messages =
                        new_history:append_replay_source(saved_replay_source)
                    if not copy_ok then
                        Logger.notify(
                            "Failed to switch provider: "
                                .. (copy_err or "unable to copy chat history"),
                            vim.log.levels.ERROR
                        )
                        self._is_switching_provider = false
                        return
                    else
                        new_history:save(function(save_err)
                            if save_err then
                                Logger.debug(
                                    "Failed to save provider switch history:",
                                    save_err
                                )
                            end
                        end)
                    end
                    self._history_replay_source = {
                        kind = "messages",
                        messages = copied_messages or {},
                    }
                    self._history_to_send = nil
                    self._is_first_message = true
                    self._is_switching_provider = false
                end,
            })
        end)
    end)

    if not new_agent then
        self._is_switching_provider = false
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
    self.provider_name = provider_name
end

function SessionManager:add_selection_or_file_to_session()
    local added_selection = self:add_selection_to_session()

    if not added_selection then
        self:add_file_to_session()
    end
end

---@param provider_name agentic.UserConfig.ProviderName
---@return boolean
function SessionManager:uses_provider(provider_name)
    local provider_config = Config.acp_providers[provider_name]
    return provider_config ~= nil
        and self.agent ~= nil
        and (
            self.provider_name == provider_name
            or self.agent.provider_config == provider_config
        )
end

---@return boolean
function SessionManager:has_messages()
    if self.chat_history == nil then
        return false
    end
    if
        self.chat_history.message_count
        and self.chat_history.message_count > 0
    then
        return true
    end
    return self.chat_history.messages ~= nil and #self.chat_history.messages > 0
end

---@param provider_name agentic.UserConfig.ProviderName
---@return "creating"|"blank"|nil
function SessionManager:get_new_session_reuse_reason(provider_name)
    if not SessionManager.uses_provider(self, provider_name) then
        return nil
    end

    if self._is_creating_session then
        return "creating"
    end

    if self.session_id ~= nil and not SessionManager.has_messages(self) then
        return "blank"
    end

    return nil
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
            return self.widget:open_buf_in_editor_window(bufnr)
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

    -- Startup config options arrive outside the session-update path, so custom
    -- function headers need an explicit refresh to pick up model/runtime state.
    self:schedule_header_refresh()
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

    local replay_source = history:get_replay_source()

    -- Prevent constructor's auto-new_session from running
    self._restoring = true
    self._history_replay_source = replay_source
    self._history_to_send = nil
    self._is_first_message = false
    local sessions_folder = opts.replace_session
            and replay_source.sessions_folder
        or ChatHistory.get_sessions_folder(self.tab_page_id)
    self.chat_history = ChatHistory:new(sessions_folder)
    self.chat_history.title = history.title

    -- In continue mode, remember original identity to restore after new_session
    local original_session_id = opts.replace_session and history.session_id
        or nil
    local original_created_at = opts.replace_session and history.created_at
        or nil
    local original_updated_at = opts.replace_session and history.updated_at
        or nil

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
            if original_created_at then
                self.chat_history.created_at = original_created_at
            end
            if original_updated_at then
                self.chat_history.updated_at = original_updated_at
            end

            local copy_ok, copy_err =
                self.chat_history:append_replay_source(replay_source)
            if not copy_ok then
                Logger.notify(
                    "Failed to restore chat history: "
                        .. (copy_err or "unable to copy history"),
                    vim.log.levels.ERROR
                )
                self._restoring = false
                return
            else
                self.chat_history:save(function(save_err)
                    if save_err then
                        Logger.debug(
                            "Failed to save restored history:",
                            save_err
                        )
                    end
                end)
            end
            if
                self.chat_history.message_count == 0
                and history.message_count
                and history.message_count > 0
            then
                self.chat_history.message_count = history.message_count
            end

            self._restoring = false
            SessionRestore.replay_messages_from_source(
                self.message_writer,
                self._history_replay_source
            )
        end,
    })
end

return SessionManager
