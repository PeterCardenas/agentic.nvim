local Logger = require("agentic.utils.logger")
local Config = require("agentic.config")
local DefaultConfig = require("agentic.config_default")
local ACPHealth = require("agentic.acp.acp_health")

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

--- @class agentic.SessionRegistry
--- @field sessions table<integer, agentic.SessionManager|nil> Map: tab_page_id -> SessionManager instance
local SessionRegistry = {
    sessions = {},
}

--- @param tab_page_id integer|nil
--- @param callback fun(session: agentic.SessionManager)|nil
--- @return agentic.SessionManager|nil session valid session instance or nil on failure
function SessionRegistry.get_session_for_tab_page(tab_page_id, callback)
    local resolved_tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    --- @cast resolved_tab_page_id integer
    local instance = SessionRegistry.sessions[resolved_tab_page_id]

    if not instance then
        if not ACPHealth.check_configured_provider() then
            Logger.debug("Session creation aborted: No configured ACP provider")
            return nil
        end

        local SessionManager = require("agentic.session_manager")

        instance = SessionManager:new(resolved_tab_page_id)
        if instance ~= nil then
            SessionRegistry.sessions[resolved_tab_page_id] = instance
        end
    end

    if instance and callback then
        local ok, err = pcall(callback, instance)

        if not ok then
            Logger.notify("Session create callback error: " .. vim.inspect(err))
        end
    end

    return instance
end

--- Destroys any existing session for the given tab page and creates a new one
--- @param tab_page_id integer|nil
--- @return agentic.SessionManager|nil
function SessionRegistry.new_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()

    SessionRegistry.destroy_session(tab_page_id)

    local new_session = SessionRegistry.get_session_for_tab_page(tab_page_id)
    return new_session
end

--- Destroys the session for the given tab page, if it exists and removes it from the registry
--- @param tab_page_id integer|nil
function SessionRegistry.destroy_session(tab_page_id)
    tab_page_id = tab_page_id ~= nil and tab_page_id
        or vim.api.nvim_get_current_tabpage()
    local session = SessionRegistry.sessions[tab_page_id]

    if session then
        SessionRegistry.sessions[tab_page_id] = nil

        local ok, err = pcall(function()
            session:destroy()
        end)
        if not ok then
            Logger.debug("Session destroy error:", err)
        end
    end
end

--- @param on_selected fun(provider_name: agentic.UserConfig.ProviderName|nil) Callback that will be called with the selected provider name, if any
function SessionRegistry.select_provider(on_selected)
    local available_providers = ACPHealth.get_default_provider_names()

    --- @class _ProviderStatus
    --- @field name string
    --- @field installed boolean

    --- @type _ProviderStatus[]
    local sorted_providers = {}

    --- @type _ProviderStatus[]
    local not_installed = {}

    for _, provider_name in ipairs(available_providers) do
        local provider_config = Config.acp_providers[provider_name]
        if
            provider_config
            and ACPHealth.is_command_available(provider_config.command)
        then
            sorted_providers[#sorted_providers + 1] = {
                name = provider_name,
                installed = true,
            }
        else
            not_installed[#not_installed + 1] = {
                name = provider_name,
                installed = false,
            }
        end
    end

    vim.list_extend(sorted_providers, not_installed)

    --- @param item _ProviderStatus
    --- @return string
    local function format_provider(item)
        local label = item.name

        if label == Config.provider then
            label = label .. " (current)"
        elseif label == DefaultConfig.provider then
            label = label .. " (default)"
        end

        label = label
            .. (item.installed and " ✓ available" or " ✗ not installed")

        return label
    end

    local fzf = load_fzf_lua()

    if not fzf then
        vim.ui.select(sorted_providers, {
            prompt = "Select an ACP provider for the new session:",
            format_item = format_provider,
        }, function(selected_provider)
            on_selected(selected_provider and selected_provider.name)
        end)
        return
    end

    local entries = {}
    for _, provider in ipairs(sorted_providers) do
        table.insert(entries, format_provider(provider))
    end

    fzf.fzf_exec(entries, {
        prompt = "Select Provider> ",
        winopts = {
            height = 0.4,
            width = 0.6,
            row = 0.5,
            col = 0.5,
        },
        actions = {
            ["default"] = function(selected)
                if not selected or #selected == 0 then
                    on_selected(nil)
                    return
                end

                for _, provider in ipairs(sorted_providers) do
                    if format_provider(provider) == selected[1] then
                        --- @cast provider.name agentic.UserConfig.ProviderName
                        on_selected(provider.name)
                        return
                    end
                end
                on_selected(nil)
            end,
        },
    })
end

return SessionRegistry
