local Logger = require("agentic.utils.logger")

--- @class agentic.States
local M = {}

--- Slash commands from the ACP provider (shared across all tabpages)
--- @type agentic.acp.CompletionItem[]
local slash_commands = {}

--- Listeners called when slash commands are updated
--- @type fun(items: agentic.acp.CompletionItem[])[]
local slash_commands_listeners = {}

--- Register a listener called whenever slash commands are updated
--- @param callback fun(items: agentic.acp.CompletionItem[])
function M.onSlashCommandsUpdate(callback)
    table.insert(slash_commands_listeners, callback)
end

--- Safely set a state value, because the buffer/tab/window may not exist anymore
--- @param accessor table vim.b, vim.g, vim.w, or vim.t
--- @param id integer|string The buffer number, tabpage number, or other identifier
--- @param key string The key to set
--- @param value string|number|boolean|table Only raw lua values, no functions or userdata
--- @return nil
local function safe_set(accessor, id, key, value)
    local ok, err = pcall(function()
        accessor[id][key] = value
    end)

    if not ok then
        Logger.debug(
            "Failed to set state for id:",
            tostring(id),
            "key:",
            key,
            "error:",
            err
        )
    end
end

--- Safely get a state value, because the buffer/tab/window may not exist anymore
--- @param accessor table vim.b, vim.g, vim.w, or vim.t
--- @param id integer|string The buffer number, tabpage number, or other identifier
--- @param key string The key to get
--- @return any
local function safe_get(accessor, id, key)
    local ok, result = pcall(function()
        return accessor[id][key]
    end)

    if not ok then
        Logger.debug(
            "Failed to get state for id:",
            tostring(id),
            "key:",
            key,
            "error:",
            result
        )
        return nil
    end

    return result
end

--- Slash commands from the ACP provider, shared across all tabpages
--- @param items agentic.acp.CompletionItem[]
function M.setSlashCommands(items)
    slash_commands = items
    for _, cb in ipairs(slash_commands_listeners) do
        pcall(cb, items)
    end
end

--- Retrieve slash commands
--- @return agentic.acp.CompletionItem[]
function M.getSlashCommands()
    return slash_commands
end

return M
