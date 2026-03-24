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
