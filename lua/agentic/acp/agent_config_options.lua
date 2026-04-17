local BufHelpers = require("agentic.utils.buf_helpers")
local Config = require("agentic.config")
local Logger = require("agentic.utils.logger")

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

--- @param target agentic.acp.ConfigOption|nil
--- @return string[] lines
local function build_config_option_preview_lines(target)
    local lines = {
        "# Option Preview",
        "",
    }

    if not target then
        table.insert(lines, "_Option preview unavailable_")
        return lines
    end

    table.insert(lines, string.format("%s (`%s`)", target.name, target.id))

    if target.description and target.description ~= "" then
        table.insert(lines, "")
        table.insert(lines, (target.description:gsub("\n", " ")))
    end

    table.insert(lines, "")

    if not target.options or #target.options == 0 then
        table.insert(lines, "_No values_")
        return lines
    end

    local current_value = target.currentValue
    local current_name = current_value
    for _, option in ipairs(target.options) do
        if option.value == current_value then
            current_name = option.name
            break
        end
    end

    table.insert(
        lines,
        string.format("current: %s (`%s`)", current_name, current_value)
    )
    table.insert(lines, "values:")

    local max_preview_values = 8
    local shown = math.min(#target.options, max_preview_values)
    local shown_count = 0
    for _, option in ipairs(target.options) do
        shown_count = shown_count + 1
        if shown_count > shown then
            break
        end
        local prefix = option.value == current_value and "*" or "-"
        table.insert(
            lines,
            string.format("%s %s (`%s`)", prefix, option.name, option.value)
        )
    end

    if #target.options > shown then
        table.insert(
            lines,
            string.format("... +%d more", #target.options - shown)
        )
    end

    return lines
end

--- @param options_by_id table<string, agentic.acp.ConfigOption>
--- @return table
local function create_config_option_previewer(options_by_id)
    --- @diagnostic disable-next-line: unresolved-require
    local builtin = require("fzf-lua.previewer.builtin")
    local previewer = builtin.base:extend()

    function previewer:new(o, opts, fzf_win)
        self.super.new(self, o, opts, fzf_win)
        setmetatable(self, previewer)
        return self
    end

    function previewer:populate_preview_buf(entry_str)
        local option_id = entry_str and entry_str:match("^([^\t]+)")
        local option = option_id and options_by_id[option_id] or nil

        local buf = self:get_tmp_buffer()
        vim.bo[buf].filetype = "markdown"
        vim.bo[buf].modifiable = true
        vim.api.nvim_buf_set_lines(
            buf,
            0,
            -1,
            false,
            build_config_option_preview_lines(option)
        )
        vim.bo[buf].readonly = true
        vim.bo[buf].modifiable = false
        self:set_preview_buf(buf)

        if self.win and self.win.update_preview_title then
            self.win:update_preview_title(
                option and option.name or "Session option"
            )
        end
    end

    return previewer
end

--- @class agentic.acp.AgentConfigOptions
--- @field mode? agentic.acp.ConfigOption
--- @field model? agentic.acp.ConfigOption
--- @field thought_level? agentic.acp.ConfigOption
--- @field all_options table<string, agentic.acp.ConfigOption>
--- @field legacy_agent_modes agentic.acp.AgentModes
--- @field legacy_agent_models agentic.acp.AgentModels
local AgentConfigOptions = {}
AgentConfigOptions.__index = AgentConfigOptions

--- @param buffers agentic.ui.ChatWidget.BufNrs Same buffers as ChatWidget instance
--- @param set_mode_callback fun(mode_id: string, is_legacy: boolean)
--- @param set_model_callback fun(model_id: string, is_legacy: boolean)
--- @param set_config_option_callback fun(config_id: string, option_value: string)|nil
--- @return agentic.acp.AgentConfigOptions
function AgentConfigOptions:new(
    buffers,
    set_mode_callback,
    set_model_callback,
    set_config_option_callback
)
    local AgentModes = require("agentic.acp.agent_modes")
    local AgentModels = require("agentic.acp.agent_models")

    self = setmetatable({
        mode = nil,
        model = nil,
        thought_level = nil,
        all_options = {},
        legacy_agent_modes = AgentModes:new(),
        legacy_agent_models = AgentModels:new(),
    }, self)

    set_config_option_callback = set_config_option_callback
        or function(_config_id, _option_value)
            -- no-op
        end

    for _, bufnr in pairs(buffers) do
        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.change_mode,
            bufnr,
            function()
                self:show_mode_selector(set_mode_callback)
            end,
            { desc = "Agentic: Select Agent Mode" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_model,
            bufnr,
            function()
                self:show_model_selector(set_model_callback)
            end,
            { desc = "Agentic: Select Model" }
        )

        BufHelpers.multi_keymap_set(
            Config.keymaps.widget.switch_config_option,
            bufnr,
            function()
                self:show_config_option_picker(function(config_id, option_value)
                    set_config_option_callback(config_id, option_value)
                end)
            end,
            { desc = "Agentic: Select Config Option" }
        )
    end

    return self
end

function AgentConfigOptions:clear()
    self.mode = nil
    self.model = nil
    self.thought_level = nil
    self.all_options = {}
    self.legacy_agent_modes:clear()
    self.legacy_agent_models:clear()
end

--- @param configOptions agentic.acp.ConfigOption[]|nil
function AgentConfigOptions:set_options(configOptions)
    self:clear()

    if not configOptions then
        return
    end

    for _i, option in ipairs(configOptions) do
        self.all_options[option.id] = option

        if option.category == "mode" then
            self.mode = option
        elseif option.category == "model" then
            self.model = option
        elseif option.category == "thought_level" then
            self.thought_level = option
        else
            Logger.debug("Unknown config option", option)
        end
    end
end

--- Modes from providers that don't support the new Config Options
--- @param modes_info agentic.acp.ModesInfo
function AgentConfigOptions:set_legacy_modes(modes_info)
    self.legacy_agent_modes:set_modes(modes_info)
end

--- Models from providers that don't support the new Config Options
--- @param models_info agentic.acp.ModelsInfo
function AgentConfigOptions:set_legacy_models(models_info)
    self.legacy_agent_models:set_models(models_info)
end

--- @param target_mode string|nil
--- @param handle_mode_change fun(mode: string, is_legacy: boolean|nil): nil
function AgentConfigOptions:set_initial_mode(target_mode, handle_mode_change)
    if not target_mode or target_mode == "" then
        Logger.debug("not setting initial mode", target_mode)
        return
    end

    local is_legacy = false
    local can_switch = false

    if self:get_mode(target_mode) ~= nil then
        --- @diagnostic disable-next-line: need-check-nil
        can_switch = target_mode ~= self.mode.currentValue
        Logger.debug("Setting initial config mode", target_mode, can_switch)
    elseif self.legacy_agent_modes:get_mode(target_mode) ~= nil then
        is_legacy = true
        can_switch = target_mode ~= self.legacy_agent_modes.current_mode_id
        Logger.debug("Setting initial legacy mode", target_mode, can_switch)
    end

    if can_switch then
        handle_mode_change(target_mode, is_legacy)
    else
        local current = self.mode and self.mode.currentValue
            or self.legacy_agent_modes.current_mode_id
            or "unknown"
        Logger.notify(
            string.format(
                "Configured default_mode ‘%s’ not available. "
                    .. "Using provider’s default ‘%s’",
                target_mode,
                current
            ),
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end
end

--- @return agentic.acp.ConfigOption[] sorted_options
function AgentConfigOptions:get_all_options_sorted()
    --- @type agentic.acp.ConfigOption[]
    local sorted_options = {}

    for _, option in pairs(self.all_options) do
        table.insert(sorted_options, option)
    end

    table.sort(sorted_options, function(a, b)
        return string.lower(a.name) < string.lower(b.name)
    end)

    return sorted_options
end

--- @param target agentic.acp.ConfigOption|nil
--- @param value string
--- @return agentic.acp.ConfigOption.Option|nil
local function getter(target, value)
    if not target or not target.options or #target.options == 0 then
        return nil
    end

    for _, option in ipairs(target.options) do
        if option.value == value then
            return option
        end
    end

    return nil
end

--- @param mode_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_mode(mode_value)
    return getter(self.mode, mode_value)
end

--- @param mode_value string
--- @return string|nil mode_name
function AgentConfigOptions:get_mode_name(mode_value)
    local mode = self:get_mode(mode_value)

    if mode then
        return mode.name
    end

    local legacy_mode = self.legacy_agent_modes:get_mode(mode_value)

    if legacy_mode then
        return legacy_mode.name
    end

    return nil
end

--- @param model_value string
--- @return agentic.acp.ConfigOption.Option|nil
function AgentConfigOptions:get_model(model_value)
    return getter(self.model, model_value)
end

--- @param handle_mode_change fun(mode: string, is_legacy: boolean): nil
--- @return boolean shown
function AgentConfigOptions:show_mode_selector(handle_mode_change)
    local shown = self:_show_selector(
        self.mode,
        "Select agent mode config:",
        handle_mode_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_modes:show_mode_selector(
        function(mode)
            handle_mode_change(mode, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support mode switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param handle_model_change fun(model_id: string, is_legacy: boolean): nil
--- @return boolean shown
function AgentConfigOptions:show_model_selector(handle_model_change)
    local shown = self:_show_selector(
        self.model,
        "Select model to change:",
        handle_model_change
    )

    if shown then
        return true
    end

    local legacy_shown = self.legacy_agent_models:show_model_selector(
        function(model_id)
            handle_model_change(model_id, true)
        end
    )

    if not legacy_shown then
        Logger.notify(
            "This provider does not support model switching",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
    end

    return legacy_shown
end

--- @param handle_option_change fun(config_id: string, option_value: string): nil
--- @return boolean shown
function AgentConfigOptions:show_config_option_picker(handle_option_change)
    local options = self:get_all_options_sorted()
    if #options == 0 then
        Logger.notify(
            "This provider does not expose configurable options",
            vim.log.levels.WARN,
            { title = "Agentic" }
        )
        return false
    end

    local fzf = load_fzf_lua()

    --- @param item agentic.acp.ConfigOption
    --- @return string
    local function format_option(item)
        local label = string.format("%s [%s]", item.name, item.id)
        if item.description and item.description ~= "" then
            return string.format("%s - %s", label, item.description)
        end
        return label
    end

    --- @param selected_option agentic.acp.ConfigOption|nil
    local function on_select_option(selected_option)
        if not selected_option then
            return
        end

        self:_show_selector(
            selected_option,
            string.format("Select value for %s:", selected_option.name),
            function(option_value, _is_legacy)
                handle_option_change(selected_option.id, option_value)
            end
        )
    end

    if not fzf then
        vim.ui.select(options, {
            prompt = "Select config option:",
            format_item = format_option,
        }, on_select_option)
        return true
    end

    local entries = {}
    --- @type table<string, agentic.acp.ConfigOption>
    local options_by_id = {}
    for _, option in ipairs(options) do
        options_by_id[option.id] = option
        table.insert(
            entries,
            string.format("%s\t%s", option.id, format_option(option))
        )
    end

    fzf.fzf_exec(entries, {
        prompt = "Select config option> ",
        winopts = {
            height = 0.4,
            width = 0.7,
            row = 0.5,
            col = 0.5,
        },
        previewer = function()
            return create_config_option_previewer(options_by_id)
        end,
        fzf_opts = {
            ["--delimiter"] = "\t",
            ["--with-nth"] = "2..",
        },
        actions = {
            ["default"] = function(selected)
                if not selected or #selected == 0 then
                    on_select_option(nil)
                    return
                end

                local option_id = selected[1]:match("^([^\t]+)")
                on_select_option(option_id and options_by_id[option_id] or nil)
            end,
        },
    })

    return true
end

--- @param target agentic.acp.ConfigOption|nil
--- @param prompt string
--- @param handle_change fun(mode: string, is_legacy: boolean): nil
--- @return boolean shown
function AgentConfigOptions:_show_selector(target, prompt, handle_change)
    local _ = self
    if not target or not target.options or #target.options == 0 then
        return false
    end

    local fzf = load_fzf_lua()

    --- @param item agentic.acp.ConfigOption.Option
    --- @return string
    local function format_option(item)
        local prefix = item.value == target.currentValue and "● " or "  "

        if item.description and item.description ~= "" then
            return string.format(
                "%s%s: %s",
                prefix,
                item.name,
                item.description
            )
        end
        return prefix .. item.name
    end

    local on_select = function(selected)
        if selected and selected.value ~= target.currentValue then
            handle_change(selected.value, false)
        end
    end

    if not fzf then
        vim.ui.select(target.options, {
            prompt = prompt,
            format_item = format_option,
        }, on_select)
        return true
    end

    local entries = {}
    for _, option in ipairs(target.options) do
        table.insert(entries, format_option(option))
    end

    fzf.fzf_exec(entries, {
        prompt = prompt:gsub(":$", "") .. "> ",
        winopts = {
            height = 0.4,
            width = 0.6,
            row = 0.5,
            col = 0.5,
        },
        actions = {
            ["default"] = function(selected)
                if not selected or #selected == 0 then
                    on_select(nil)
                    return
                end

                for _, option in ipairs(target.options) do
                    if format_option(option) == selected[1] then
                        on_select(option)
                        return
                    end
                end
                on_select(nil)
            end,
        },
    })

    return true
end

return AgentConfigOptions
