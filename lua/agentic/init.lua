local Config = require("agentic.config")
local AgentInstance = require("agentic.acp.agent_instance")
local Theme = require("agentic.theme")
local SessionRegistry = require("agentic.session_registry")
local SessionRestore = require("agentic.session_restore")
local Object = require("agentic.utils.object")
local Logger = require("agentic.utils.logger")

--- @class agentic.Agentic
local Agentic = {}

--- Opens the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.open(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end

        session.widget:show(opts)
    end)
end

--- Closes the chat widget for the current tab page
--- Safe to call multiple times
function Agentic.close()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:hide()
    end)
end

--- Toggles the chat widget for the current tab page
--- Safe to call multiple times
--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.toggle(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.widget:is_open() then
            session.widget:hide()
        else
            if not opts or opts.auto_add_to_context ~= false then
                session:add_selection_or_file_to_session()
            end

            session.widget:show(opts)
        end
    end)
end

--- Rotates through predefined window layouts for the chat widget
--- @param layouts agentic.UserConfig.Windows.Position[]|nil
function Agentic.rotate_layout(layouts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session.widget:rotate_layout(layouts)
    end)
end

--- Add the current visual selection to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_to_session()
        session.widget:show(opts)
    end)
end

--- Add the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_file(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_file_to_session()
        session.widget:show(opts)
    end)
end

--- Add either the current visual selection or the current file to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_selection_or_file_to_context(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:add_selection_or_file_to_session()
        session.widget:show(opts)
    end)
end

--- @class agentic.ui.NewSessionOpts : agentic.ui.ChatWidget.ShowOpts
--- @field provider? agentic.UserConfig.ProviderName

--- Add diagnostics at the current cursor line to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_current_line_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_current_line_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
        else
            Logger.notify(
                "No diagnostics found on the current line",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Add all diagnostics from the current buffer to the Chat context
--- @param opts agentic.ui.ChatWidget.AddToContextOpts|nil
function Agentic.add_buffer_diagnostics(opts)
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        local count = session:add_buffer_diagnostics_to_context()
        if count > 0 then
            session.widget:show(opts)
        else
            Logger.notify(
                "No diagnostics found in the current buffer",
                vim.log.levels.INFO
            )
        end
    end)
end

--- Destroys the current Chat session and starts a new one
--- If the widget is already open, reuses existing windows instead of creating new ones
--- @param opts agentic.ui.NewSessionOpts|nil
function Agentic.new_session(opts)
    if opts and opts.provider then
        Config.provider = opts.provider
    end

    local tab_page_id = vim.api.nvim_get_current_tabpage()
    local old_session = SessionRegistry.sessions[tab_page_id]

    --- @type agentic.ui.ChatWidget.WinNrs|nil
    local saved_win_nrs

    -- If widget is already open, preserve windows for reuse
    if old_session and old_session.widget:is_open() then
        saved_win_nrs = {}
        for name, winid in pairs(old_session.widget.win_nrs) do
            if winid and vim.api.nvim_win_is_valid(winid) then
                saved_win_nrs[name] = winid
                -- Disable winfixbuf so Neovim can switch buffers during cleanup
                vim.wo[winid].winfixbuf = false
            end
        end
        -- Detach windows from old widget so destroy() won't close them
        old_session.widget.win_nrs = {}
    end

    local session = SessionRegistry.new_session()
    if session then
        -- Transfer preserved windows to new widget
        if saved_win_nrs then
            for name, winid in pairs(saved_win_nrs) do
                if vim.api.nvim_win_is_valid(winid) then
                    session.widget.win_nrs[name] = winid
                end
            end
        end

        if not opts or opts.auto_add_to_context ~= false then
            session:add_selection_or_file_to_session()
        end
        session.widget:show(opts)
    end
end

--- @param opts agentic.ui.ChatWidget.ShowOpts|nil
function Agentic.new_session_with_provider(opts)
    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            local merged_opts = vim.tbl_deep_extend("force", opts or {}, {
                provider = provider_name,
            }) --[[@as agentic.ui.NewSessionOpts]]

            Agentic.new_session(merged_opts)
        end
    end)
end

--- @class agentic.ui.SwitchProviderOpts
--- @field provider? agentic.UserConfig.ProviderName

--- @param provider_name agentic.UserConfig.ProviderName
local function apply_provider_switch(provider_name)
    Config.provider = provider_name
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:switch_provider()
    end)
end

--- Switch to a different provider while preserving chat UI and history.
--- If opts.provider is set, switches directly. Otherwise shows a picker.
--- @param opts agentic.ui.SwitchProviderOpts|nil
function Agentic.switch_provider(opts)
    if opts and opts.provider then
        apply_provider_switch(opts.provider)
        return
    end

    SessionRegistry.select_provider(function(provider_name)
        if provider_name then
            apply_provider_switch(provider_name)
        end
    end)
end

--- Switch to a different model via fzf-lua picker.
function Agentic.switch_model()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:switch_model()
    end)
end

--- Switch a session config option via two-step picker (option/value).
function Agentic.switch_config_option()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        session:switch_config_option()
    end)
end

--- Stops the agent's current generation or tool execution
--- The session remains active and ready for the next prompt
--- Safe to call multiple times or when no generation is active
function Agentic.stop_generation()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if session.is_generating then
            session.agent:stop_generation(session.session_id)
            session.permission_manager:clear()
            session.is_generating = false
            session.status_animation:stop()
        end
    end)
end

--- show a selector to restore a previous session
function Agentic.restore_session()
    local tab_page_id = vim.api.nvim_get_current_tabpage()
    SessionRestore.show_picker(tab_page_id)
end

--- Toggle between prompt and code window
--- If cursor is in the prompt window, jump to the code window
--- Otherwise, jump to the prompt window
--- If the widget is not open, this does nothing
function Agentic.toggle_prompt_code()
    SessionRegistry.get_session_for_tab_page(nil, function(session)
        if not session.widget:is_open() then
            return
        end

        local current_win = vim.api.nvim_get_current_win()
        local input_winid = session.widget.win_nrs.input

        -- If currently in prompt, go to code window
        if current_win == input_winid then
            local code_winid = session.widget:find_first_non_widget_window()
            if code_winid then
                vim.api.nvim_set_current_win(code_winid)
            end
        else
            -- Otherwise, go to prompt
            session.widget:focus_prompt()
        end
    end)
end

--- Used to make sure we don't set multiple signal handlers or autocmds, if the user calls setup multiple times
local traps_set = false
local cleanup_group = vim.api.nvim_create_augroup("AgenticCleanup", {
    clear = true,
})

--- Merges the current user configuration with the default configuration
--- This method should be safe to be called multiple times
--- @param opts agentic.UserConfig
function Agentic.setup(opts)
    -- make sure invalid user config doesn't crash setup and leave things half-initialized
    local ok, err = pcall(function()
        Object.merge_config(Config, opts or {})
    end)

    if not ok then
        Logger.notify(
            "[Agentic] Error in user configuration: " .. tostring(err),
            vim.log.levels.ERROR,
            { title = "Agentic: user config merge error" }
        )
    end

    if traps_set then
        return
    end

    traps_set = true

    vim.treesitter.language.register("markdown", "AgenticChat")

    Theme.setup()

    -- Force-reload buffers when files change on disk (e.g., agent edits files directly).
    -- Suppresses the "file changed" prompt so modified buffers reload silently,
    -- matching Cursor/Zed behavior where agent changes always win.
    vim.api.nvim_create_autocmd("FileChangedShell", {
        group = cleanup_group,
        pattern = "*",
        callback = function()
            vim.v.fcs_choice = "reload"
        end,
    })

    -- Set up global keymap for toggling between prompt and code window
    vim.keymap.set(
        "n",
        Config.keymaps.widget.toggle_prompt_code,
        Agentic.toggle_prompt_code,
        { desc = "Agentic: Toggle prompt/code", silent = true }
    )

    -- Set up global keymap for switching models
    vim.keymap.set(
        "n",
        Config.keymaps.widget.switch_model_global,
        Agentic.switch_model,
        { desc = "Agentic: Switch model", silent = true }
    )

    -- Set up global keymap for switching config options
    vim.keymap.set(
        "n",
        Config.keymaps.widget.switch_config_option_global,
        Agentic.switch_config_option,
        { desc = "Agentic: Switch config option", silent = true }
    )

    vim.api.nvim_create_autocmd("VimLeavePre", {
        group = cleanup_group,
        callback = function()
            AgentInstance:cleanup_all()
        end,
        desc = "Cleanup Agentic processes on exit",
    })

    -- Cleanup sessions whose tabpage no longer exists.
    -- TabClosed ev.match gives the tab page number (position), not the handle,
    -- so we scan all sessions instead of using ev.match as a key.
    vim.api.nvim_create_autocmd("TabClosed", {
        group = cleanup_group,
        callback = function()
            for tab_id, _ in pairs(SessionRegistry.sessions) do
                if not vim.api.nvim_tabpage_is_valid(tab_id) then
                    SessionRegistry.destroy_session(tab_id)
                end
            end
        end,
        desc = "Cleanup Agentic processes on tab close",
    })

    if Config.image_paste.enabled then
        local function get_current_session()
            local tab_page_id = vim.api.nvim_get_current_tabpage()
            return SessionRegistry.sessions[tab_page_id]
        end

        local Clipboard = require("agentic.ui.clipboard")

        Clipboard.setup({
            is_cursor_in_widget = function()
                local session = get_current_session()
                return session and session.widget:is_cursor_in_widget() or false
            end,
            on_paste = function(file_path)
                local session = get_current_session()

                if not session then
                    return false
                end

                local ret = session.file_list:add(file_path) or false

                if ret then
                    session.widget:show({
                        focus_prompt = false,
                    })
                end

                return ret
            end,
        })
    end

    -- Setup signal handlers for graceful shutdown
    local sigterm_handler = vim.uv.new_signal()
    if sigterm_handler then
        vim.uv.signal_start(sigterm_handler, "sigterm", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end

    -- SIGINT handler (Ctrl-C) - note: may not trigger in raw terminal mode
    local sigint_handler = vim.uv.new_signal()
    if sigint_handler then
        vim.uv.signal_start(sigint_handler, "sigint", function(_sigName)
            AgentInstance:cleanup_all()
        end)
    end
end

return Agentic
