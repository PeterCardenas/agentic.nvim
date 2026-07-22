local Config = require("agentic.config")

--- Truncate large tool call bodies for chat buffer display and compact history.
--- @class agentic.utils.ToolCallBody
local M = {}

--- @return integer|nil max_lines nil means no limit
function M.get_max_display_lines()
    local folding = Config.folding
    local tool_calls = folding and folding.tool_calls
    if not tool_calls then
        return 500
    end

    return tool_calls.max_display_lines
end

--- @param body string[]|nil
--- @param max_lines integer|nil
--- @return string[] display_lines
--- @return boolean truncated
function M.truncate_for_display(body, max_lines)
    if not body or #body == 0 then
        return {}, false
    end

    if not max_lines or max_lines <= 0 or #body <= max_lines then
        return body, false
    end

    --- @type string[]
    local display = {}
    for i = 1, max_lines do
        display[i] = body[i]
    end

    local omitted = #body - max_lines
    table.insert(display, string.format("... (%d more lines omitted)", omitted))

    return display, true
end

return M
