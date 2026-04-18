--- @class agentic.States
local M = {}

--- Slash commands from the ACP provider, scoped to the prompt buffer.
--- @type table<integer, agentic.acp.CompletionItem[]>
local slash_commands_by_buffer = {}

--- Listeners called when slash commands are updated for a prompt buffer.
--- @type table<integer, fun(items: agentic.acp.CompletionItem[])[]>
local slash_commands_listeners_by_buffer = {}

--- @param bufnr integer|nil
--- @return integer|nil
local function resolve_bufnr(bufnr)
    if bufnr and bufnr > 0 then
        return bufnr
    end

    local ok, current_bufnr = pcall(vim.api.nvim_get_current_buf)
    if not ok or current_bufnr <= 0 then
        return nil
    end

    return current_bufnr
end

--- Register a listener called whenever slash commands are updated for a buffer.
--- @param bufnr integer|nil
--- @param callback fun(items: agentic.acp.CompletionItem[])
--- @return fun()
function M.onSlashCommandsUpdate(bufnr, callback)
    local resolved_bufnr = resolve_bufnr(bufnr)
    if not resolved_bufnr then
        return function() end
    end

    local listeners = slash_commands_listeners_by_buffer[resolved_bufnr]
    if not listeners then
        listeners = {}
        slash_commands_listeners_by_buffer[resolved_bufnr] = listeners
    end

    table.insert(listeners, callback)

    return function()
        local current_listeners =
            slash_commands_listeners_by_buffer[resolved_bufnr]
        if not current_listeners then
            return
        end

        for index, listener in ipairs(current_listeners) do
            if listener == callback then
                table.remove(current_listeners, index)
                break
            end
        end

        if #current_listeners == 0 then
            slash_commands_listeners_by_buffer[resolved_bufnr] = nil
        end
    end
end

--- Slash commands from the ACP provider, scoped to the prompt buffer.
--- @param bufnr integer|nil
--- @param items agentic.acp.CompletionItem[]
function M.setSlashCommands(bufnr, items)
    local resolved_bufnr = resolve_bufnr(bufnr)
    if not resolved_bufnr then
        return
    end

    slash_commands_by_buffer[resolved_bufnr] = items

    local listeners = slash_commands_listeners_by_buffer[resolved_bufnr]
    if not listeners then
        return
    end

    local listeners_snapshot = vim.list_extend({}, listeners)
    for _, callback in ipairs(listeners_snapshot) do
        pcall(callback, items)
    end
end

--- Retrieve slash commands for a prompt buffer.
--- @param bufnr integer|nil
--- @return agentic.acp.CompletionItem[]
function M.getSlashCommands(bufnr)
    local resolved_bufnr = resolve_bufnr(bufnr)
    if not resolved_bufnr then
        return {}
    end

    return slash_commands_by_buffer[resolved_bufnr] or {}
end

return M
